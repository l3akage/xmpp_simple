module XMPPSimple
  class Client
    include Celluloid::IO
    finalizer :finalize

    def initialize(handler, username, password, host, port = 5223)
      raise 'username, password, host and port must be set' if [username, password, host, port].include?(nil)
      @username = Jid.new(username, host)
      @password = password
      @host = host
      @port = port
      @handler = handler
      @parser = nil
    end

    def connect
      XMPPSimple.info "Connecting to #{@host}:#{@port}"
      raw_socket = Celluloid::IO::TCPSocket.new(@host, @port)
      @socket = Celluloid::IO::SSLSocket.new(raw_socket).connect
      start
      async.run
      self
    end

    def disconnect
      write_data close_stream_xml
    end

    def start
      @parser = Parser.new(self)
      write_data open_stream_xml
    end

    def reconnect
      finalize
      connect
    end

    def process(node)
      XMPPSimple.debug "Process: #{node}"
      return unless respond_to?(node.name)
      return unless %w(features success message iq).include?(node.name)
      send(node.name, node)
    end

    def write_data(xml)
      xml = xml.respond_to?(:to_xml) ? xml.to_xml : xml
      XMPPSimple.debug "Sending: #{xml}"
      @socket.write xml
    end

    def features(node)
      XMPPSimple.debug "Features: #{node.class}"
      if node.at('/features/bind:bind', 'bind' => 'urn:ietf:params:xml:ns:xmpp-bind')
        write_data Bind.create
      elsif node.at('/features/sasl:mechanisms', 'sasl' => 'urn:ietf:params:xml:ns:xmpp-sasl')
        mechanisms = node.xpath('/features/sasl:mechanisms/sasl:mechanism',
                                'sasl' => 'urn:ietf:params:xml:ns:xmpp-sasl')
        if mechanisms.any? { |m| m.inner_text == 'PLAIN' }
          write_data PlainAuth.create(@username, @password)
        else
          XMPPSimple.info 'No authentication method provided'
          disconnect
        end
      end
    end

    def success(_node)
      start
    end

    def message(node)
      @handler.message(node.to_xml) if @handler.respond_to? :message
    end

    def iq(node)
      XMPPSimple.debug "Iq: #{node.inspect}"
      return unless node.at('/iq/bind:bind', 'bind' => 'urn:ietf:params:xml:ns:xmpp-bind')
      XMPPSimple.debug 'Connected!'
      @handler.connected if @handler.respond_to? :connected
    end

    def run
      loop do
        @parser << @socket.readpartial(4096)
      end
    rescue EOFError
      XMPPSimple.debug 'Socket disconnected'
      @handler.disconnected if @handler.respond_to? :disconnected
    rescue => e
      XMPPSimple.debug "Error: #{e} => Reconnecting"
      @handler.reconnecting if @handler.respond_to? :reconnecting
      reconnect
    end

    def finalize
      return unless defined? @socket
      return if @socket.nil?
      disconnect
      @socket.close
    end

    def open_stream_xml
      <<-XML
<stream:stream
  xmlns:stream='http://etherx.jabber.org/streams'
  xmlns='jabber:client'
  to='#{@host}'
  xml:lang='en'
  version='1.0'>
      XML
    end

    def close_stream_xml
      '</stream>'
    end
  end
end
