require 'puppet/provider/firewall'
require 'digest/md5'

Puppet::Type.type(:firewall).provide :iptables, :parent => Puppet::Provider::Firewall do
  include Puppet::Util::Firewall

  @doc = "Iptables type provider"

  has_feature :iptables
  has_feature :rate_limiting
  has_feature :snat
  has_feature :dnat
  has_feature :interface_match
  has_feature :icmp_match
  has_feature :owner
  has_feature :state_match
  has_feature :recent_match
  has_feature :reject_type
  has_feature :log_level
  has_feature :log_prefix
  has_feature :mark

  commands :iptables => '/sbin/iptables'
  commands :iptables_save => '/sbin/iptables-save'

  defaultfor :kernel => :linux

  @resource_map = {
    :burst => "--limit-burst",
    :destination => "-d",
    :dport => "-m multiport --dports",
    :gid => "-m owner --gid-owner",
    :icmp => "-m icmp --icmp-type",
    :iniface => "-i",
    :jump => "-j",
    :limit => "-m limit --limit",
    :log_level => "--log-level",
    :log_prefix => "--log-prefix",
    :name => "-m comment --comment",
    :outiface => "-o",
    :port => '-m multiport --ports',
    :proto => "-p",
    :reject => "--reject-with",
    :recent_set => "-m recent --set",
    :recent_update => "-m recent --update",
    :recent_remove => "-m recent --remove",
    :recent_rcheck => "-m recent --rcheck",
    :recent_name => "--name",
    :recent_rsource => "--rsource",
    :recent_rdest => "--rdest",
    :recent_seconds => "--seconds",
    :recent_hitcount => "--hitcount",
    :recent_rttl => "--rttl",
    :source => "-s",
    :state => "-m state --state",
    :sport => "-m multiport --sports",
    :table => "-t",
    :tcp_flags => "-m tcp --tcp-flags",
    :todest => "--to-destination",
    :toports => "--to-ports",
    :tosource => "--to-source",
    :uid => "-m owner --uid-owner",
    :set_mark => "--set-mark",
  }

  # This is the order of resources as they appear in iptables-save output,
  # we need it to properly parse and apply rules, if the order of resource
  # changes between puppet runs, the changed rules will be re-applied again.
  # This order can be determined by going through iptables source code or just tweaking and trying manually
  @resource_list = [:table, :source, :destination, :iniface, :outiface,
    :proto, :tcp_flags, :gid, :uid, :sport, :dport, :port, :name, :state, :icmp, :limit, :burst,
    :recent_update, :recent_set, :recent_rcheck, :recent_remove, :recent_seconds, :recent_hitcount,
    :recent_rttl, :recent_name, :recent_rsource, :recent_rdest,
    :jump, :todest, :tosource, :toports, :log_level, :log_prefix, :reject, :set_mark]
  @resource_list_noargs = [:recent_set, :recent_update, :recent_rcheck, :recent_remove, :recent_rsource, :recent_rdest]

  def insert
    debug 'Inserting rule %s' % resource[:name]
    iptables insert_args
  end

  def update
    debug 'Updating rule  %s' % resource[:name]
    iptables update_args
  end

  def delete
    debug 'Deleting rule %s' % resource[:name]
    iptables delete_args
  end

  def exists?
    properties[:ensure] != :absent
  end

  # Flush the property hash once done.
  def flush
    debug("[flush]")
    if @property_hash.delete(:needs_change)
      notice("Properties changed - updating rule")
      update
    end
    @property_hash.clear
  end

  def self.instances
    debug "[instances]"
    table = nil
    rules = []
    counter = 1

    # String#lines would be nice, but we need to support Ruby 1.8.5
    iptables_save.split("\n").each do |line|
      unless line =~ /^\#\s+|^\:\S+|^COMMIT/
        if line =~ /^\*/
          table = line.sub(/\*/, "")
        else
          if hash = rule_to_hash(line, table, counter)
            rules << new(hash)
            counter += 1
          end
        end
      end
    end
    rules
  end

  def self.rule_to_hash(line, table, counter)
    hash = {}
    keys = []
    values = line.dup

    # --tcp-flags takes two values; we cheat by adding " around it
    # so it behaves like --comment
    values = values.sub(/--tcp-flags (\S*) (\S*)/, '--tcp-flags "\1 \2"')

    # instead of slicing out table with the rest of the options, remove it
    # completely from the line, since it's already passed anyway.
    # Without this, it trips up the order of keys and values and
    # exchanges chain and table, since iptables --list-rules lists
    # tables before chains.
    values.slice!("-t %s" % table)

    @resource_list.reverse.each do |k|
      search = /(.*)#{@resource_map[k]}(.*)/
      # options that take no arguments should get a placeholder empty ""
      # so keys and values still match
      if @resource_list_noargs.include?(k)
        replace = '""'
      else
        replace = ''
      end
      new = values.sub(search, "\\1%s\\2" % replace)
      if values != new
        keys << k
        values = new
      end
    end

    # Manually remove chain
    values.slice!('-A')
    keys << :chain

    # keys now contains a list of the keys present in line,
    # and values is a string of the matching space-separated option values,
    # but reversed

    # some params don't take a value, for example some recent_
    keys.zip(values.scan(/"[^"]*"|\S+/).reverse) { |f, v|
      hash[f] = v ? v.gsub(/"/, '') : nil }

    [:dport, :sport, :port, :state].each do |prop|
      hash[prop] = hash[prop].split(',') if ! hash[prop].nil?
    end

    # Our type prefers hyphens over colons for ranges so ...
    # Iterate across all ports replacing colons with hyphens so that ranges match
    # the types expectations.
    [:dport, :sport, :port].each do |prop|
      next unless hash[prop]
      hash[prop] = hash[prop].collect do |elem|
        elem.gsub(/:/,'-')
      end
    end

    # States should always be sorted. This ensures that the output from
    # iptables-save and user supplied resources is consistent.
    hash[:state] = hash[:state].sort unless hash[:state].nil?

    # This forces all existing, commentless rules to be moved to the bottom of the stack.
    # Puppet-firewall requires that all rules have comments (resource names) and will fail if
    # a rule in iptables does not have a comment. We get around this by appending a high level
    if ! hash[:name]
      hash[:name] = "9999 #{Digest::MD5.hexdigest(line)}"
    end

    # Iptables defaults to log_level '4', so it is omitted from the output of iptables-save.
    # If the :jump value is LOG and you don't have a log-level set, we assume it to be '4'.
    if hash[:jump] == 'LOG' && ! hash[:log_level]
      hash[:log_level] = '4'
    end

    # Handle recent module

    hash[:recent_command] = :set if hash.include?(:recent_set)
    hash[:recent_command] = :update if hash.include?(:recent_update)
    hash[:recent_command] = :remove if hash.include?(:recent_remove)
    hash[:recent_command] = :rcheck if hash.include?(:recent_rcheck)

    [:recent_set, :recent_update, :recent_remove, :recent_rcheck].each do |key|
      hash.delete(key)

    # rsource is the default if rdest isn't set and recent is being used
    hash[:recent_rsource] = true if \
        hash.key?:recent_command and ! hash[:recent_rdest]
    end

    hash[:line] = line
    hash[:provider] = self.name.to_s
    hash[:table] = table
    hash[:ensure] = :present

    # Munge some vars here ...

    # Proto should equal 'all' if undefined
    hash[:proto] = "all" if !hash.include?(:proto)

    # If the jump parameter is set to one of: ACCEPT, REJECT or DROP then
    # we should set the action parameter instead.
    if ['ACCEPT','REJECT','DROP'].include?(hash[:jump]) then
      hash[:action] = hash[:jump].downcase
      hash.delete(:jump)
    end

    hash
  end

  def insert_args
    args = []
    args << ["-I", resource[:chain], insert_order]
    args << general_args
    args
  end

  def update_args
    args = []
    args << ["-R", resource[:chain], insert_order]
    args << general_args
    args
  end

  def delete_args
    count = []
    line = properties[:line].gsub(/\-A/, '-D').split

    # Grab all comment indices
    line.each do |v|
      if v =~ /"/
        count << line.index(v)
      end
    end

    if ! count.empty?
      # Remove quotes and set first comment index to full string
      line[count.first] = line[count.first..count.last].join(' ').gsub(/"/, '')

      # Make all remaining comment indices nil
      ((count.first + 1)..count.last).each do |i|
        line[i] = nil
      end
    end

    # Return array without nils
    line.compact
  end

  def general_args
    debug "Current resource: %s" % resource.class

    args = []
    resource_list = self.class.instance_variable_get('@resource_list')
    resource_list_noargs = self.class.instance_variable_get('@resource_list_noargs')
    resource_map = self.class.instance_variable_get('@resource_map')
    resource_list_recent_commands = [:recent_set, :recent_update, :recent_rcheck, :recent_remove]

    resource_list.each do |res|

      # get the additional arguments to put after the resource map snippet
      resource_value = nil
      if ! resource_list_noargs.include?(res) then
        if (resource[res]) then
          resource_value = resource[res]
        elsif res == :jump and resource[:action] then
          # In this case, we are substituting jump for action
          resource_value = resource[:action].to_s.upcase
        else
          next
        end
      end

      what = res.to_s.scan(/^recent_(\w+)/)
      if !what.empty?
        # only append recent_ args if there is a recent_command
        if ! (resource['recent_command'])
          next
        end
        # only append the right recent_ command
        if resource_list_recent_commands.include?(res) and \
            resource['recent_command'].to_s != what[0][0]
          next
        end
        # only append rsource/rdest if set
        if res == :recent_rsource and not resource['recent_rsource']:
            next
        end
        if res == :recent_rdest and not resource['recent_rdest']:
            next
        end
       end
      
      args << resource_map[res].split(' ')

      # For sport and dport, convert hyphens to colons since the type
      # expects hyphens for ranges of ports.
      if [:sport, :dport, :port].include?(res) then
        resource_value = resource_value.collect do |elem|
          elem.gsub(/-/, ':')
        end
      end

      if !resource_list_noargs.include?(res) then
        # our tcp_flags takes a single string with comma lists separated
        # by space
        # --tcp-flags expects two arguments
        if res == :tcp_flags
          one, two = resource_value.split(' ')
          args << one
          args << two
        elsif resource_value.is_a?(Array)
          args << resource_value.join(',')
        else
          args << resource_value
        end
      end
    end

    args
  end

  def insert_order
    debug("[insert_order]")
    rules = []

    # Find list of current rules based on chain
    self.class.instances.each do |rule|
      rules << rule.name if rule.chain == resource[:chain].to_s
    end

    # No rules at all? Just bail now.
    return 1 if rules.empty?

    my_rule = resource[:name].to_s
    rules << my_rule
    rules.sort.index(my_rule) + 1
  end
end
