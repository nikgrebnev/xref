# -*- encoding : utf-8 -*-
require 'spec_helper'

# Parsing the front-end configuration (the specification).
#
# All four rules here come from an incident, and each of them DOES NOT FAIL in
# the config: the front end quietly starts serving the wrong thing. So the spec
# checks not only that a defect is found but also that it is NOT found where
# everything is fine: for `rewrite … last` the first version of the rule yielded
# 25 findings while two were real.
RSpec.describe Xref::Nginx do
  describe 'the structure' do
    it 'remembers the nesting: a directive knows its location' do
      source = <<~CONF
        server {
          location /img/ {
            proxy_pass http://images;
          }
        }
      CONF
      found = described_class.elements(source).find { |e| e.name == 'proxy_pass' }

      expect(found.scope).to eq('server > location /img/')
      expect(found.args).to eq('http://images')
    end

    it 'does not treat a comment as a directive' do
      expect(described_class.elements("# proxy_pass http://нет;\n")).to be_empty
    end

    it 'takes only the directives people ask about' do
      source = "gzip_types text/plain;\nproxy_pass http://rails;\n"

      expect(described_class.elements(source).map(&:name)).to eq(['proxy_pass'])
    end
  end

  # The most valuable finding: an unanchored name matches SOMEBODY ELSE'S
  # address, and the host starts answering for it. Here that swallowed two
  # production addresses.
  describe 'a virtual-host regexp' do
    it 'with no anchors is a finding' do
      expect(described_class.unanchored_server_name?('~^(.+)\.example\.com')).to be(true)
      expect(described_class.unanchored_server_name?('~example')).to be(true)
    end

    it 'with anchors on both sides is not a finding' do
      expect(described_class.unanchored_server_name?('~^(.+)\.example\.com$')).to be(false)
    end

    it 'does not treat an ordinary name as a regexp' do
      expect(described_class.unanchored_server_name?('example.com www.example.com')).to be(false)
    end
  end

  describe 'rewrite … last' do
    it 'recognises a re-selection of the location' do
      expect(described_class.rewrite_restarts?('^/a$ /b last')).to be(true)
      expect(described_class.rewrite_restarts?('^/a$ /b permanent')).to be(false)
    end
  end

  describe 'http_404 in proxy_next_upstream' do
    it 'recognises the doubling of the load on a 404' do
      expect(described_class.next_upstream_doubles?('error timeout http_404')).to be(true)
      expect(described_class.next_upstream_doubles?('error timeout')).to be(false)
    end
  end
end
