test_name "Puppet cert generate behavior (#6112)" do

  # This acceptance test documents the behavior of `puppet cert generate` calls for three cases:
  #
  # 1) On a host which has ssl/ca infrastructure.  Typically this would be the
  # puppet master which is also the CA, and the expectation is that this is the
  # host that `puppet cert generate` commands should be issued on.
  #
  # This case should succeed as it is the documented use case for the command.
  #
  # 2) On a host which has no ssl/ca infrastructure but has a valid ca.pem from
  # the CA cached in ssl/cert.  This would be a host (let's say CN=foo) with a
  # puppet agent that has checked in and received a signed ca.pem and foo.pem
  # certificate from the master CA.
  #
  # Talking with Nick Fagerlund, this behavior is unspecified, although it
  # should not result in a certificate.  And it currently fails with "Error:
  # The certificate retrieved from the master does not match the agent's
  # private key."  This error messaging is a little misleading, in that it is
  # strictly speaking true but does not point out that it is the CA cert and
  # local CA keys that are involved.
  #
  # What happens is `puppet cert generate` starts by creating a local
  # CertificateAuthority instance which looks for a locally cached
  # ssl/cert/ca.pem, generating ssl/ca/ keys in the process.  It finds an
  # ssl/cert/ca.pem, because we have the master CA's pem, but this certificate
  # does not match the keys in ssl/ca that have just been generated (for the
  # local CA instance), and validation of the cert fails with the above error.
  #
  # 3) On a host which has no ssl infrastructure at all (fresh install, hasn't
  # tried to send a CSR to the puppet master yet).
  #
  # Tracing this case, what happens is that `puppet cert generate` starts by
  # creating a local CertificateAuthority instance which looks for a locally
  # cached ssl/cert/ca.pem.  It does not find one and then procedes to
  # generate_ca_certificate, which populates a local ssl/ca with public/private
  # keys for a local ca cert, creates a CSR locally for this cert, which it
  # then signs and saves in ssl/ca/ca_crt.pem and caches in ssl/certs/ca.pem.
  # (This is the normal bootstrapping case for a CA; same thing happens during an
  # initial `puppet master` run).
  #
  # This case succeeds, but future calls such as `puppet agent -t` fail.
  # Haven't fully traced what happens here.

  teardown do
    step "And try to leave with a good ssl configuration"
    reset_master_and_agent_ssl
  end

  def clean_cert(host, cn)
    on(host, puppet('cert', 'clean', cn))
    assert_match(/remov.*Certificate.*#{cn}/i, stdout, "Should see a log message that certificate request was removed.")
    on(host, puppet('cert', 'list', '--all'))
    assert_no_match(/#{cn}/, stdout, "Should not see certificate in list anymore.")
  end

  def generate_and_clean_cert(host, cn, autosign)
    on(host, puppet('cert', 'generate', cn, '--autosign', autosign))
    assert_no_match(/Could not find certificate request for.*cert\.test/i, stderr, "Should not see an error message for a missing certificate request.")
    clean_cert(host, cn)
  end

  def fail_to_generate_cert_on_agent_that_is_not_ca(host, cn, autosign)
    on(host, puppet('cert', 'generate', cn, '--autosign', autosign), :acceptable_exit_codes => [23])
    assert_match(/Error: The certificate retrieved from the master does not match the agent's private key./, stderr, "Should not be able to generate a certificate on an agent that is not also the CA, with autosign false.")
  end

  def generate_and_clean_cert_with_dns_alt_names(host, cn, autosign)
    on(host, puppet('cert', 'generate', cn, '--autosign', autosign, '--dns_alt_names', 'foo,bar'))
    on(master, puppet('cert', 'list', '--all'))
    assert_match(/cert.test.*DNS:foo/, stdout, "Should find a dns entry for 'foo' in the cert.test listing.")
    assert_match(/cert.test.*DNS:bar/, stdout, "Should find a dns entry for 'bar' in the cert.test listing.")
    clean_cert(host, cn)
  end

  # @return true if the passed host operates in a master role.
  def host_is_master?(host)
    host['roles'].include?('master')
  end

  def clear_all_hosts_ssl
    step "All: Clear ssl settings"
    on( hosts, host_command('rm -rf #{host["puppetpath"]}/ssl') )
  end

  def reset_master_and_agent_ssl
    clear_all_hosts_ssl

    step "Master: Ensure the master bootstraps CA"
    with_master_running_on(master, "--certname #{master} --autosign true") do
      step "Agents: Run agent --test once to obtained auto-signed cert"
      on agents, puppet('agent', "--test --server #{master}"), :acceptable_exit_codes => [0,2]
    end
  end

  cn = "cert.test"

  ################
  # Cases 1 and 2:

  step "Case 1 and 2: Tests behavior of `puppet cert generate` on a master node, and on an agent node that has already authenticated to the master.  Tests with combinations of autosign and dns_alt_names."

  reset_master_and_agent_ssl

  # User story:
  # A root user on the puppet master has a configuration where autosigning is
  # explicitly false.  They run 'puppet cert generate foo.bar' for a new
  # certificate and expect a certificate to be generated and signed because they
  # are the root CA, and autosigning should not effect this.
  step "puppet cert generate with autosign false"

  hosts.each do |host|
    if host_is_master?(host)
      generate_and_clean_cert(host, cn, false)
    else
      fail_to_generate_cert_on_agent_that_is_not_ca(host, cn, false)
    end
  end

  # User story:
  # A root user on the puppet master has a configuration where autosigning is
  # explicitly true.  They run 'puppet cert generate foo.bar' for a new
  # certificate and expect a certificate to be generated and signed without
  # interference from the autosigning setting.  (This succeedes in 3.2.2 and
  # earlier but produces an extraneous error message per #6112 because there are
  # two attempts to sign the CSR, only the first of which succedes due to the CSR
  # already haveing been signed and removed.)
  step "puppet cert generate with autosign true"

  hosts.each do |host|
    if host_is_master?(host)
      generate_and_clean_cert(host, cn, true)
    else
      fail_to_generate_cert_on_agent_that_is_not_ca(host, cn, true)
    end
  end

  # These steps are documenting the current behavior with regard to --dns_alt_names
  # flags submitted on the command line with a puppet cert generate.
  step "puppet cert generate with autosign false and dns_alt_names"

  hosts.each do |host|
    if host_is_master?(host)
      generate_and_clean_cert_with_dns_alt_names(host, cn, false)
    else
      fail_to_generate_cert_on_agent_that_is_not_ca(host, cn, false)
    end
  end

  step "puppet cert generate with autosign true and dns_alt_names"
  hosts.each do |host|
    if host_is_master?(host)
      generate_and_clean_cert_with_dns_alt_names(host, cn, false)
    else
      fail_to_generate_cert_on_agent_that_is_not_ca(host, cn, false)
    end
  end

  #########
  # Case 3:

  # Attempting to run this in a windows machine fails during the CA generation
  # attempting to set the ssl/ca/serial file.  Fails inside
  # Puppet::Settings#readwritelock because we can't overwrite the lock file in
  # Windows.
  confine :except, :platform => 'windows'

  step "Case 3: A host with no ssl infrastructure makes a `puppet cert generate` call"

  clear_all_hosts_ssl

  step "puppet cert generate"

  hosts.each do |host|
    generate_and_clean_cert(host, cn, false)

# Commenting this out until we can figure out whether this behavior is a bug or
# not, and what the platform issues are.
#
# Need to figure out exactly why this fails, where it fails, and document or
# fix.  Can reproduce a failure locally in Ubuntu, and the attempt fails
# 'as expected' in Jenkins acceptance jobs on Lucid and Fedora, but succeeds
# on RHEL and Centos...
#
# Redmine (#21739) captures this.
#
#    with_master_running_on(master, "--certname #{master} --autosign true", :preserve_ssl => true) do
#      step "but now unable to authenticate normally as an agent"
# 
#      on(host, puppet('agent', '-t'), :acceptable_exit_codes => [1])
#
#    end
  end

  ##########
  # PENDING: Test behavior of `puppet cert generate` with an external ca.

end
