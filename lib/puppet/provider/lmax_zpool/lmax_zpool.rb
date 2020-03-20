Puppet::Type.type(:lmax_zpool).provide(:lmax_zpool) do
  desc "Provider for zpool."

  commands :zpool => 'zpool'

  # NAME    SIZE  ALLOC   FREE    CAP  HEALTH  ALTROOT
  def self.instances
    zpool(:list, '-H').split("\n").collect do |line|
      name, _size, _alloc, _free, _cap, _health, _altroot = line.split(/\s+/)
      new({:name => name, :ensure => :present})
    end
  end

  def process_zpool_data(pool_array)
    if pool_array == []
      return Hash.new(:absent)
    end
    # get the name and get rid of it
    pool = Hash.new
    pool[:pool] = pool_array[0]
    pool_array.shift

    tmp = []

    # order matters here :(
    pool_array.reverse_each do |value|
      sym = nil
      case value
      when "spares";
        sym = :spare
      when "logs";
        sym = :log
      when /^mirror|^raidz1|^raidz2/;
        sym = value =~ /^mirror/ ? :mirror : :raidz
        pool[:raid_parity] = "raidz2" if value =~ /^raidz2/
      else
        # handle cases where we strip off the partition number/name from various /dev/...
        # full paths.
        if /(\/dev\/[a-z]{3}(1))$/ =~ value
          tmp << value.chomp($2)
        elsif /(\/dev\/disk\/by-id\/.+)-part1/ =~ value
          tmp << $1
        else
          tmp << value
        end
        sym = :disk if value == pool_array.first
      end

      if sym
        pool[sym] = pool[sym] ? pool[sym].unshift(tmp.reverse.join(' ')) : [tmp.reverse.join(' ')]
        tmp.clear
      end
    end

    pool
  end

  def get_pool_data
    # https://docs.oracle.com/cd/E19082-01/817-2271/gbcve/index.html
    # we could also use zpool iostat -v mypool for a (little bit) cleaner output
    out = execute("zpool status -P #{@resource[:pool]}", :failonfail => false, :combine => false)
    zpool_data = out.lines.select { |line| line.index("\t") == 0 }.collect { |l| l.strip.split("\s")[0] }
    zpool_data.shift
    zpool_data
  end

  def current_pool
    @current_pool = process_zpool_data(get_pool_data) unless (defined?(@current_pool) and @current_pool)
    @current_pool
  end

  def flush
    @current_pool= nil
  end

  # Adds log and spare
  def build_named(name)
    puts name
    puts @resource[name.intern]
    if prop = @resource[name.intern]
      [name] + prop.collect { |p| p.split(' ') }.flatten
    else
      []
    end
  end

  # query for parity and set the right string
  def raidzarity
    @resource[:raid_parity] ? @resource[:raid_parity] : "raidz1"
  end

  # handle mirror or raid
  def handle_multi_arrays(prefix, array)
    array.collect{ |a| [prefix] +  a.split(' ') }.flatten
  end

  # builds up the vdevs for create command
  def build_vdevs
    if disk = @resource[:disk]
      disk.collect { |d| d.split(' ') }.flatten
    elsif mirror = @resource[:mirror]
      handle_multi_arrays("mirror", mirror)
    elsif raidz = @resource[:raidz]
      handle_multi_arrays(raidzarity, raidz)
    end
  end

  def create
    zpool(*([:create, @resource[:pool]] + build_vdevs + build_named("spare") + build_named("log")))
  end

  def destroy
    zpool :destroy, @resource[:pool]
  end

  def exists?
    if current_pool[:pool] == :absent
      false
    else
      true
    end
  end

  [:disk, :mirror, :raidz, :log, :spare].each do |field|
    define_method(field) do
      current_pool[field]
    end

    define_method(field.to_s + "=") do |should|
      self.fail "zpool #{field} can't be changed. should be #{should}, currently is #{current_pool[field]}"
    end
  end

  [:ashift].each do |field|
    define_method(field) do
      zpool(:get, "-H", "-o", "value", field, @resource[:name]).strip
    end

    define_method(field.to_s + "=") do |should|
      zpool(:set, "#{field}=#{should}", @resource[:name])
    end
  end

end

