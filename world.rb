# HellGround.rb, WoW protocol implementation in Ruby
# Copyright (C) 2014 Siarkowy <siarkowy@siarkowy.net>
# See LICENSE file for more information on licensing.

# World related code.
module HellGround::World
  module SMSG
    SMSG_AUTH_CHALLENGE               = 0x01EC
    SMSG_CHAR_ENUM                    = 0x003B
    SMSG_LOGOUT_COMPLETE              = 0x004D
    SMSG_NAME_QUERY_RESPONSE          = 0x0051
    SMSG_ITEM_QUERY_SINGLE_RESPONSE   = 0x0058
    SMSG_QUEST_QUERY_RESPONSE         = 0x005D
    SMSG_CONTACT_LIST                 = 0x0067
    SMSG_FRIEND_STATUS                = 0x0068
    SMSG_GUILD_ROSTER                 = 0x008A
    SMSG_GUILD_EVENT                  = 0x0092
    SMSG_MESSAGECHAT                  = 0x0096
    SMSG_CHANNEL_NOTIFY               = 0x0099
    SMSG_CHANNEL_LIST                 = 0x009B
    SMSG_NOTIFICATION                 = 0x01CB
    SMSG_AUTH_RESPONSE                = 0x01EE
    SMSG_LOGIN_VERIFY_WORLD           = 0x0236
    SMSG_CHAT_PLAYER_NOT_FOUND        = 0x02A9
    SMSG_MOTD                         = 0x033D
    SMSG_USERLIST_ADD                 = 0x03EF
    SMSG_USERLIST_UPDATE              = 0x03F1
  end

  require_relative 'world/includes'

  class Connection < EM::Connection
    attr_reader :chars, :chat, :guild, :social
    attr_writer :callbacks

    include HellGround::Utils
    include Handlers

    def initialize(app, username, key, callbacks)
      extend HellGround::Callbacks

      @app = app
      @callbacks = callbacks # use provided callback hash

      @key = key
      @username = username

      @buf = ''
    end

    def post_init
      notify :world_opened
    end

    def receive_data(data)
      @buf << data

      loop do
        # header length check
        return if @buf.length < 4

        # decrypt header
        unless @crypto.nil?
          @buf[0..3] = @crypto.decrypt @buf[0..3] unless @decrskip
          @decrskip = false
        end

        # handle packet
        pk = Packet.new(@buf)

        # wait for more data if needed
        if pk.underflow > 0
          @decrskip = true
          return
        end

        @buf = pk.overflow || ''
        receive_packet(pk)
        next
      end
    end

    def receive_packet(pk)
      notify :packet_received, pk
      dispatch(pk.reset)
    rescue AuthError => e
      notify :auth_error, e
      stop!
    end

    def send_data(pk)
      notify :packet_sent, pk

      pk[0..5] = @crypto.encrypt pk[0..5] unless @crypto.nil?

      super(pk.data)
    end

    def unbind
      stop!
      notify :world_closed
    end

    def stop!
      EM::stop_event_loop
    end
  end

  class AuthError < StandardError; end
end
