module Push
  class DeliveryError < StandardError
    attr_reader :code, :description, :notify

    def initialize(code, message_id, description, source, notify = true, token = nil)
      @code = code
      @message_id = message_id
      @description = description
      @source = source
      @notify = notify
      @token = token
    end

    def message
      device_token_msg = "device token: #{@token}" if @token
      ["Unable to deliver message #{@message_id}",
        device_token_msg,
        "received #{@source} error #{@code} (#{@description})",
      ].compact.join(', ')
    end
  end
end
