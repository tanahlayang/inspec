# encoding: utf-8

if ENV['DOCKER']
  STDERR.puts "\033[1;33mTODO: Not running #{__FILE__.split("/").last} because we are running in docker\033[0m"
  return
end

# lets define our own group
root_group = 'root'

if os[:family] == 'aix'
  root_group = 'system'
elsif os[:family] == 'freebsd'
  root_group = 'wheel'
elsif os.solaris?
  root_group = 'sys'
end

if os.unix?
  describe etc_group do
    its('gids') { should_not contain_duplicates }
    its('groups') { should include root_group }
    its('users') { should include 'root' }
  end

  describe etc_group.where(name: root_group) do
    its('users') { should include 'root' }
  end
end
