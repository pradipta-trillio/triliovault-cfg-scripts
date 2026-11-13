# This custom function builds the AMQP URL shared by the Trilio DMS server
# (trilio::dms) and the DMS client config of WLM and DMAPI. Both ends must
# render the identical URL, so every caller goes through this function.
#
# DMS accepts the oslo cluster form and fails over between the hosts. The
# trailing '//' selects the default '/' vhost, which is where TripleO's
# oslo_messaging_rpc user lives.
#
# Given:
#   hosts    = ["ctl-0.ctlplane.example", "ctl-1.ctlplane.example"]
#   username = "guest", password = "secret", port = 5672, use_ssl = false
# Returns:
#   "rabbit://guest:secret@ctl-0.ctlplane.example:5672,guest:secret@ctl-1.ctlplane.example:5672//"
#
# With use_ssl true the URL ends in "//?ssl=1". IPv6 hosts are bracketed.
Puppet::Functions.create_function(:'dms_rabbitmq_url') do
  dispatch :dms_rabbitmq_url do
    param 'Array', :hosts
    param 'String', :username
    param 'String', :password
    param 'Variant[String, Integer]', :port
    param 'Variant[String, Boolean, Integer]', :use_ssl
    return_type 'String'
  end

  def dms_rabbitmq_url(hosts, username, password, port, use_ssl)
    entries = hosts.map do |host|
      host = host.to_s
      host = "[#{host}]" if host.include?(':') && !host.start_with?('[')
      "#{username}:#{password}@#{host}:#{port}"
    end
    ssl = ['true', 'yes', '1', 'y'].include?(use_ssl.to_s.strip.downcase)
    "rabbit://#{entries.join(',')}//#{ssl ? '?ssl=1' : ''}"
  end
end
