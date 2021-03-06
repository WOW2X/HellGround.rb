# HellGround.rb, WoW protocol implementation in Ruby
# Copyright (C) 2014 Siarkowy <siarkowy@siarkowy.net>
# See LICENSE file for more information on licensing.

module HellGround::World
  # Server packet handlers.
  #
  # All server packets begin with 4 byte header consisting of:
  #   uint16 - packet size (big endian)
  #   uint16 - opcode number (little endian)
  #
  # Headers after +SMSG_AUTH_CHALLENGE+ packet are encrypted. Packet contents
  # are not encrypted. All numeric data is little endian. Only the packet
  # size field of the header is sent as big endian.
  module Handlers
    private

    SMSG_HANDLERS = {}

    public

    def self.on(opcode, &handler)
      SMSG_HANDLERS[opcode] = handler
    end

    def dispatch(pk)
      handler = SMSG_HANDLERS[pk.opcode]
      instance_exec(pk.skip(4), &handler) if handler
    end

    on SMSG::SMSG_AUTH_CHALLENGE do |pk|
      raise Packet::MalformedError unless pk.length == 8

      @server_seed = pk.uint32
      @client_seed = 0xBB40E64D
      @digest = sha1(@username + (0).hexpack(4) + @client_seed.hexpack(4) +
                     @server_seed.hexpack(4) + @key.hexpack(40))

      send_data Packets::ClientAuthSession.new(@username, @client_seed, @digest)

      @crypto = CryptoMgr.new(@key)
    end

    on SMSG::SMSG_AUTH_RESPONSE do |pk|
      raise AuthError, "Server authentication response error" unless pk.uint8 == 0x0C

      send_data Packets::ClientCharEnum.new
    end

    on SMSG::SMSG_CHANNEL_NOTIFY do |pk|
      type  = pk.uint8
      name  = pk.str

      notify :channel_notification_received, ChannelNotification.new(type, name)
    end

    on SMSG::SMSG_CHAR_ENUM do |pk|
      @chars = []

      num = pk.uint8

      num.times do
        guid  = pk.uint64
        name  = pk.str
        race  = pk.uint8
        cls   = pk.uint8
        level = pk.skip(6).uint8
        pk.skip(221) # location, pet info, inventory data

        @chars << Player.new(guid, name, level, race, cls)
      end

      notify :character_enum, self
    end

    def login(name)
      if player = @chars.select { |player| player.to_char.name == name }.first
        @player = player
        send_data Packets::ClientPlayerLogin.new(player)
        return true
      end

      false
    end

    on SMSG::SMSG_CHAT_PLAYER_NOT_FOUND do |pk|
      notify :player_not_found, pk.str
    end

    on SMSG::SMSG_CONTACT_LIST do |pk|
      pk.skip(4).uint32.times do
        guid  = pk.uint64
        flags = pk.uint32
        note  = pk.str

        if flags & SocialInfo::SOCIAL_FLAG_FRIEND > 0
          status = pk.uint8

          unless status == SocialInfo::FRIEND_STATUS_OFFLINE
            area  = pk.uint32
            level = pk.uint32
            cls   = pk.uint32
          end
        end

        send_data Packets::ClientNameQuery.new(guid) unless Character.find(guid)

        social = @social.find(guid)

        if social
          social.update(flags, note, status, area, level, cls)
        else
          @social.introduce SocialInfo.new(guid, flags, note, status, area, level, cls)
        end
      end
    end

    on SMSG::SMSG_FRIEND_STATUS do |pk|
      send_data Packets::ClientContactList.new
    end

    on SMSG::SMSG_GUILD_ROSTER do |pk|
      num   = pk.uint32
      motd  = pk.str
      ginfo = pk.str

      pk.uint32.times { pk.skip 56 } # rank info

      num.times do
        guid  = pk.uint64
        online = pk.uint8
        name  = pk.str
        rank  = pk.uint32
        level = pk.uint8
        cls   = pk.uint8
        zone  = pk.skip(1).uint32
        offline_time = pk.float * 86400 if online == 0
        note  = pk.str
        onote = pk.str

        @guild.update(guid, name, nil, cls, online, rank, level, zone, offline_time, note, onote)
      end

      notify :guild_updated, @guild
    end

    on SMSG::SMSG_ITEM_QUERY_SINGLE_RESPONSE do |pk|
      id    = pk.uint32
      return if id & Item::INVALID_FLAG > 0
      name  = pk.skip(12).str

      Item.new(id, name)
    end

    on SMSG::SMSG_LOGIN_VERIFY_WORLD do |pk|
      @chat     = ChatMgr.new self
      @guild    = GuildMgr.new self
      @social   = SocialMgr.new self

      send_data Packets::ClientGuildRoster.new
      notify :login_succeeded, self
    end

    on SMSG::SMSG_LOGOUT_COMPLETE do |pk|
      @player   = nil
      @chat     = nil
      @guild    = nil
      @social   = nil

      send_data Packets::ClientCharEnum.new
      notify :logout_succeeded
    end

    on SMSG::SMSG_QUEST_QUERY_RESPONSE do |pk|
      id    = pk.uint32
      name  = pk.skip(168).str

      Quest.new(id, name)
    end

    on SMSG::SMSG_MESSAGECHAT do |pk|
      type  = pk.uint8
      lang  = pk.uint32
      guid  = pk.uint64
      lang2 = pk.uint32
      chan  = pk.str if type == ChatMessage::CHAT_MSG_CHANNEL
      guid2 = pk.uint64
      len   = pk.uint32
      text  = pk.str
      tag   = pk.uint8

      @chat.receive ChatMessage.new(type, lang, guid, text, chan)
    end

    on SMSG::SMSG_MOTD do |pk|
      motd = []
      pk.uint32.times { motd << pk.str }

      notify :motd_received, motd.join("\n")
    end

    on SMSG::SMSG_NAME_QUERY_RESPONSE do |pk|
      guid  = pk.uint64
      name  = pk.str
      race  = pk.skip(1).uint32
      cls   = pk.uint32

      @chat.introduce Character.new(guid, name, race, cls)
    end

    on SMSG::SMSG_NOTIFICATION do |pk|
      notify :server_notification_received, pk.str
    end
  end
end
