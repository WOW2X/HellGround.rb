# HellGround.rb, HellGround Core chat client written in Ruby
# Copyright (C) 2014 Siarkowy <siarkowy@siarkowy.net>
# See LICENSE file for more information on licensing.

require_relative 'packet'

require 'digest/sha1'
require 'openssl'

module HellGround
  module Auth
    REALM_IP = '192.168.1.2'
    REALM_PORT = 3724

    # Packets
    CMD_AUTH_LOGON_CHALLENGE      = 0x00
    CMD_AUTH_LOGON_PROOF          = 0x01
    CMD_AUTH_RECONNECT_CHALLENGE  = 0x02
    CMD_AUTH_RECONNECT_PROOF      = 0x03
    CMD_REALM_LIST                = 0x10
    CMD_XFER_INITIATE             = 0x30
    CMD_XFER_DATA                 = 0x31

    # Authentication results
    RESULT_SUCCESS                = 0x00
    RESULT_FAIL_BANNED            = 0x03
    RESULT_FAIL_UNKNOWN_ACCOUNT   = 0x04
    RESULT_FAIL_VERSION_INVALID   = 0x09
    RESULT_FAIL_VERSION_UPDATE    = 0x0A
    RESULT_FAIL_SUSPENDED         = 0x0C
    RESULT_FAIL_LOCKED_ENFORCED   = 0x10

    # Realm flags
    REALM_FLAG_NONE               = 0x00
    REALM_FLAG_INVALID            = 0x01
    REALM_FLAG_OFFLINE            = 0x02
    REALM_FLAG_SPECIFYBUILD       = 0x04
    REALM_FLAG_UNK1               = 0x08
    REALM_FLAG_UNK2               = 0x10
    REALM_FLAG_NEW_PLAYERS        = 0x20
    REALM_FLAG_RECOMMENDED        = 0x40
    REALM_FLAG_FULL               = 0x80

    REALM_FLAG_SKIP               = REALM_FLAG_INVALID | REALM_FLAG_OFFLINE | REALM_FLAG_FULL

    RESULT_STRING = {
      RESULT_FAIL_BANNED          => 'This account has been closed and is no longer available for use',
      RESULT_FAIL_UNKNOWN_ACCOUNT => 'The information you have entered is not valid',
      RESULT_FAIL_VERSION_INVALID => 'Unable to validate game version',
      RESULT_FAIL_VERSION_UPDATE  => 'Unable to validate game version',
      RESULT_FAIL_SUSPENDED       => 'This account has been temporarily suspended',
      RESULT_FAIL_LOCKED_ENFORCED => 'You have applied a lock to your account',
    }

    N = 0x894b645e89e1535bbdad5b8b290650530801b18ebfbf5e8fab3c82872a3e9bb7
    G = 0x07

    CRC_HASH = 0x79776f6b72616953077962073e3c0762722e4748

    class Connection < EM::Connection
      include Utils

      def initialize(username, password)
        @username = username.upcase
        @password = password.upcase
      end

      def post_init
        puts "Connecting to realm server at #{REALM_IP}:#{REALM_PORT}."
        send_data ClientLogonChallenge.new(@username)
      rescue => e
        puts "Error: #{e.message}"
        stop!
      end

      def receive_data(data)
        pk = Packet.new(data)

        if VERBOSE
          puts "Recv: #{pk}"
          pk.data.hexdump
        end

        handler = SMSG_HANDLERS[pk.uint8]
        method(handler).call(pk) if handler
      rescue AuthError => e
        puts "Authentication error: #{e.message}."
        stop!
      rescue => e
        puts "#{e.message}."
        stop!
      end

      def send_data(pk)
        if VERBOSE
          puts "Send: #{pk}"
          pk.data.hexdump
        end

        super(pk.data)
      end

      def stop!
        EM::stop_event_loop
      end

      #
      # Server packet handlers
      #

      def OnLogonChallenge(pk)
        result = pk.skip(1).uint8
        raise StandardError, RESULT_STRING[result] unless result == RESULT_SUCCESS

        b = pk.hex(32)    # B
       _g = pk.uint8      # size of g
        g = pk.hex(_g)    # g
       _n = pk.uint8      # size of N
        n = pk.hex(_n)    # N
        salt = pk.hex(32) # s
        t = pk.hex(16)    # unknown
        f = pk.uint8      # flags

        raise MalformedPacketError, "Got wrong N from server" unless n == N
        raise MalformedPacketError, "Got wrong g from server" unless g == G

        k = 3
        i = sha1("#{@username}:#{@password}")       # i = H(C|:|P)
        x = sha1(salt.hexpack(32) + i.hexpack(20))  # x = H(salt|i)
        v = g.to_bn.mod_exp(x, n).to_i              # v = g ** x % N
       _a = OpenSSL::Random.random_bytes(32).unpack("H*").first.hex # a = rand()
        a = g.to_bn.mod_exp(_a, n).to_i             # A  = g ** a % N

        # check whether A % N == 0
        raise MalformedPacketError, "Public key equal zero" if a.to_bn.mod_exp(1, n) == 0

        # u = H(A|B)
        u = sha1(a.hexpack(32) + b.hexpack(32))

        # S = (B - k * g ** x % N) ** (a + u * x) % N
        s = (b - k * g.to_bn.mod_exp(x, n)).to_bn.mod_exp(_a + u * x, n).to_i

        even = ''
        odd = ''

        ['%064x' % s].pack('H*').split('').each_slice(2) { |e, o| even << e; odd << o }

        even = Digest::SHA1.digest(even.reverse).reverse
        odd = Digest::SHA1.digest(odd.reverse).reverse
        @key = even.split('').zip(odd.split('')).flatten.compact.join.unpack('H*').first.hex

        gnhash = Digest::SHA1.digest(n.hexpack(32)).reverse
        ghash = Digest::SHA1.digest(g.hexpack(1)).reverse
        (0..19).each { |i| gnhash[i] = (gnhash[i].ord ^ ghash[i].ord).chr }
        gnhash = gnhash.unpack('H*').first.hex

        userhash = sha1(@username)
        m1 = sha1(gnhash.hexpack(20) + userhash.hexpack(20) + salt.hexpack(32) +
             a.hexpack(32) + b.hexpack(32) + @key.hexpack(40))
        @m2 = sha1(a.hexpack(32) + m1.hexpack(20) + @key.hexpack(40))

        send_data ClientLogonProof.new(a, m1, CRC_HASH)
      end

      def OnLogonProof(pk)
        result = pk.uint8
        raise AuthError, RESULT_STRING[result] unless result == RESULT_SUCCESS

        m2 = pk.hex(20)       # M2
        accFlags = pk.uint32  # account flags
        surveyId = pk.uint32  # survey id
        unkFlags = pk.uint16  # unknown flags

        stop! unless m2 == @m2 # check server key
        @m2 = nil

        puts "Authentication successful. Requesting realm list."

        send_data ClientRealmList.new
      end

      def OnRealmList(pk)
        @realms = []

        size = pk.uint16
        unused = pk.uint32
        num_realms = pk.uint16

        num_realms.times do
          type  = pk.uint8
          lock  = pk.uint8
          flags = pk.uint8
          name  = pk.str
          addr  = pk.str
          popul = pk.float
          chars = pk.uint8
          zone  = pk.uint8
          unk   = pk.uint8

          unless flags & REALM_FLAG_SPECIFYBUILD == 0
            maj = pk.uint8
            min = pk.uint8
            fix = pk.uint8
            build = pk.uint16
          end

          if flags & REALM_FLAG_SKIP == 0 # && lock == 0
            host, port = addr.split(':')
            puts "Discovered realm #{name} at #{addr}."
            @realms << [name, host, port.to_i]
          end
        end

        raise AuthError, "No on-line realm to connect found" if @realms.empty?

        # connect to the first available server
        name, host, port = @realms[0]
        puts "Connecting to world server #{name} at #{host}:#{port}."

        close_connection
        $conn = EM::connect host, port, World::Connection, @username, @key
      end

      SMSG_HANDLERS = {
        CMD_AUTH_LOGON_CHALLENGE  => :OnLogonChallenge,
        CMD_AUTH_LOGON_PROOF      => :OnLogonProof,
        CMD_REALM_LIST            => :OnRealmList,
      }
    end

    #
    # Client packet classes
    #

    class ClientLogonChallenge < Packet
      def initialize(username)
        super()

        raise ArgumentError, "User name too short" if username.length == 0
        raise ArgumentError, "User name too long" if username.length > 32

        self.uint8  = CMD_AUTH_LOGON_CHALLENGE  # type
        self.uint8  = 8                     # error
        self.uint16 = 30 + username.length  # size
        self.raw    = "\0WoW".reverse       # gamename
        self.uint8  = 2                     # version1
        self.uint8  = 4                     # version2
        self.uint8  = 3                     # version3
        self.uint16 = 8606                  # build
        self.raw    = "\0x86".reverse       # platform
        self.raw    = "\0Cha".reverse       # os
        self.raw    = "enGB".reverse        # locale
        self.uint32 = 60                    # timezone
        self.uint32 = 0xf6876919            # ip
        self.uint8  = username.length       # namelen
        self.raw    = username.upcase       # account

        raise PacketLengthError unless length == 34 + username.length
      end
    end

    class ClientLogonProof < Packet
      def initialize(a, m1, crc_hash)
        super()

        self.uint8  = CMD_AUTH_LOGON_PROOF  # type
        self.raw    = a.hexpack(32)         # A
        self.raw    = m1.hexpack(20)        # M1
        self.raw    = crc_hash.hexpack(20)  # crc_hash unused
        self.uint8  = 0                     # num keys
        self.uint8  = 0                     # sec flag

        raise PacketLengthError unless length == 75
      end
    end

    class ClientRealmList < Packet
      def initialize
        super()

        self.uint8  = CMD_REALM_LIST        # type
        self.uint32 = 0                     # pad

        raise PacketLengthError unless length == 5
      end
    end

  end

  class AuthError < StandardError; end
end
