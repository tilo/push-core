require 'socket'

module Push
  module Daemon
    class Feeder
      extend DatabaseReconnectable
      extend InterruptibleSleep

      RESERVATION_TIME = 2.minutes
      MAX_TASKS   = 100

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
          sweep
          enqueue_notifications
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

      def self.enqueue_notifications
        begin
          with_database_reconnect_and_retry(name) do
            Push::Daemon::App.ready.each do |app|
              reserved_until = Time.now + RESERVATION_TIME

              # First reserve the notifications for delivery by this instance of the daemon
              num_reserved = Push::Message.ready_for_delivery.where(:app => app).update_all(
                {:reserved_by => us, :reserved_until => reserved_until}, :limit => MAX_TASKS
              )
              # if we succeeded with the reservation, then process the notifications
              if num_reserved > 0
                Push::Messages.where(:reserved_by => us).find_each do |notification|
                  Push::Daemon::App.deliver(notification)
                end
              else
                # someone else beat us to it
              end
            end
          end
        rescue StandardError => e
          Push::Daemon.logger.error(e)
        end
      end
    end
  end
end
