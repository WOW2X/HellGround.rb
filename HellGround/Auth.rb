# HellGround.rb, HellGround Core chat client written in Ruby
# Copyright (C) 2014 Siarkowy <siarkowy@siarkowy.net>
# See LICENSE file for more information on licensing.

require_relative 'packet'

module HellGround
  module Auth
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

    class ClientLogonChallenge < Packet
      def initialize(username)
        super()

        raise ArgumentError, "User name missing" unless username
        raise ArgumentError, "User name too short" if username.length == 0
        raise ArgumentError, "User name too long" if username.length > 32

        self.uint8  = CMD_AUTH_LOGON_CHALLENGE  # type
        self.uint8  = 8                     # error
        self.uint16 = 30 + username.length  # size
        self.str    = "\0WoW".reverse       # gamename
        self.uint8  = 2                     # version1
        self.uint8  = 4                     # version2
        self.uint8  = 3                     # version3
        self.uint16 = 8606                  # build
        self.str    = "\0x86".reverse       # platform
        self.str    = "\0Cha".reverse       # os
        self.str    = "enGB".reverse        # locale
        self.uint32 = 60                    # timezone
        self.uint32 = 0xf6876919            # ip
        self.uint8  = username.length       # namelen
        self.str    = username.upcase       # account

        raise PacketLengthError.new(self, 34 + username.length) unless length == 34 + username.length
      end
    end

    CRC_HASH = 0x79776f6b72616953077962073e3c0762722e4748

    class ClientLogonProof < Packet
      def initialize(a, m1, crc_hash)
        super()

        self.uint8  = CMD_AUTH_LOGON_PROOF  # type
        self.str    = a.hexpack(32)         # A
        self.str    = m1.hexpack(20)        # M1
        self.str    = crc_hash.hexpack(20)  # crc_hash unused
        self.uint8  = 0                     # num keys
        self.uint8  = 0                     # sec flag

        raise PacketLengthError.new(self, 75) unless length == 75
      end
    end

    class ClientRealmList < Packet
      def initialize
        super()

        self.uint8  = CMD_REALM_LIST        # type
        self.uint32 = 0                     # pad

        raise PacketLengthError.new(self, 5) unless length == 5
      end
    end
  end
end
