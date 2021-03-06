test_name "#3961: puppet ca should produce certs spec"

target  = "working3961.example.org"

expect = ['notice: Signed certificate request for ca',
          'notice: Rebuilding inventory file',
          'notice: working3961.example.org has a waiting certificate request',
          'notice: Signed certificate request for working3961.example.org',
          'notice: Removing file Puppet::SSL::CertificateRequest working3961.example.org']

agents.each do |agent|
  if agent['platform'].include?('windows')
    skip_test "Test not supported on this platform"
    next
  end

  scratch = agent.tmpdir('puppet-ssl-3961')
  options = { :confdir => scratch, :vardir => scratch }

  step "removing the SSL scratch directory..."
  on(agent, "rm -vrf #{scratch}")

  step "generate a certificate in #{scratch}"
  on(agent,puppet_cert('--trace', '--generate', target, options)) do
    expect.each do |line|
      stdout.index(line) or fail_test("missing line in output: #{line}")
    end
  end

  step "verify the certificate for #{target} exists"
  on agent, "test -f #{scratch}/ssl/certs/#{target}.pem"

  step "verify the private key for #{target} exists"
  on agent, "grep -q 'BEGIN RSA PRIVATE KEY' #{scratch}/ssl/private_keys/#{target}.pem"
end
