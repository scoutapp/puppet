if __FILE__ == $0
    $:.unshift '../../lib'
    $:.unshift '..'
    $puppetbase = "../.."
end

require 'puppet'
require 'puppet/server/authconfig'
require 'test/unit'
require 'puppettest.rb'

class TestAuthConfig < Test::Unit::TestCase
	include TestPuppet

    def test_parsingconfigfile
        file = tempfile()
        assert(Puppet[:authconfig], "No config path")

        Puppet[:authconfig] = file

        File.open(file, "w") { |f|
            f.puts "[pelementserver.describe]
    allow *.madstop.com
    deny 10.10.1.1

[fileserver]
    allow *.madstop.com
    deny 10.10.1.1

[fileserver.list]
    allow 10.10.1.1
"
        }

        config = nil
        assert_nothing_raised {
            config = Puppet::Server::AuthConfig.new(file)
        }

        assert_nothing_raised {
            assert(config.allowed?("pelementserver.describe",
                "culain.madstop.com", "1.1.1.1"), "Did not allow host")
            assert(! config.allowed?("pelementserver.describe",
                "culain.madstop.com", "10.10.1.1"), "Allowed host")
            assert(config.allowed?("fileserver.yay",
                "culain.madstop.com", "10.1.1.1"), "Did not allow host to fs")
            assert(! config.allowed?("fileserver.yay",
                "culain.madstop.com", "10.10.1.1"), "Allowed host to fs")
            assert(config.allowed?("fileserver.list",
                "culain.madstop.com", "10.10.1.1"), "Did not allow host to fs.list")
        }
    end
end

# $Id$

