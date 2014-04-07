require 'socket'

module Push
  module Daemon
    class Feeder
      extend DatabaseReconnectable
      extend InterruptibleSleep

      RESERVATION_TIME = 5.minutes # this can add latency for delivery if a daemon dies
      BATCH_SIZE = 300

      def self.name
        "Feeder"
      end

      def self.us
        Socket.gethostname + '_' + $$.to_s
      end

      def self.start(config)
        reconnect_database unless config.foreground

        loop do
          break if @stop
          sweep  # re-queue expired jobs

          with_database_reconnect_and_retry(name) do
            Push::Message.where(:reserved_by => nil).ready_for_delivery.find_in_batches(:batch_size => BATCH_SIZE) do |batch|
              enqueue_notifications(batch)
            end
          end

          interruptible_sleep config.push_poll
        end
      end

      def self.stop
        @stop = true
        interrupt_sleep
      end

      protected

      def self.sweep
        begin
          with_database_reconnect_and_retry(name) do
            # re-queue notifications with stale reservations (in case other daemon died)
            Push::Message.where("reserved_until < ?", Time.now).update_all(
              {:reserved_by => nil, :reserved_until => nil}
            )
          end
        rescue StandardError => e
          Push::Daemon.logger.error(e)
        end
      end

      def self.enqueue_notifications(batch)
        begin
          ready_apps = Push::Daemon::App.ready
          reserved_until = Time.now + RESERVATION_TIME

          # First reserve the notifications for delivery by this instance of the daemon
          num_reserved = batch.update_all(
            {:reserved_by => us, :reserved_until => reserved_until},
            :conditions => {:reserved_by => nil} # make sure noone else beat us to it
          )
          # if we succeeded with the reservation, then process the notifications
          if num_reserved > 0
            Push::Message.where(:reserved_by => us).find_each do |notification|
              if ready_apps.include?(notification.app) && (notification.reserved_until >= Time.now)
                Push::Daemon::App.deliver(notification)
              end
            end
          else
            # someone else beat us to it, or there are no notifications to be processed
          end
        rescue StandardError => e
          Push::Daemon.logger.error(e)
        end
      end
    end
  end
end
