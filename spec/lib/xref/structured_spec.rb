# -*- encoding : utf-8 -*-
require 'spec_helper'

# Parsing configuration: yaml and json (the specification).
#
# The main thing here is the ERB inside yaml: environment keys are read through
# it (`config/database.yml`, `cable.yml`, `storage.yml`), and while yaml went
# unparsed 43 such reads were invisible entirely while the report claimed "not
# read in the code".
#
# And a second rule, just as important: there are no configuration VALUES in the
# index and there cannot be — that is a password, an address or a key. Only the
# names are recorded.
RSpec.describe Xref::Structured do
  describe 'ERB inside yaml' do
    it 'is cut out with a marker rather than with emptiness: otherwise a pair stops being a pair' do
      source = "host: <%= ENV['DB_HOST'] %>\nport: 5432\n"
      tree = described_class.parse('config/database.yml', source)

      expect(tree).to eq('host' => 'xreferb', 'port' => 5432)
    end

    it 'parses yaml with ERB in a key and in a value anyway' do
      source = "<%= Rails.env %>:\n  pool: <%= ENV.fetch('DB_POOL', 5) %>\n"

      expect(described_class.parse('config/database.yml', source)).to be_a(Hash)
    end
  end

  describe 'key paths' do
    it 'gives a path to every tier rather than only to the leaf' do
      tree = { 'production' => { 'primary' => { 'host' => 'скрыто' } } }

      expect(described_class.key_paths(tree))
        .to eq(['production', 'production.primary', 'production.primary.host'])
    end

    it 'never records values' do
      tree = { 'password' => 'секрет', 'host' => 'node1' }

      expect(described_class.key_paths(tree)).to eq(%w[password host])
    end

    it 'does not number a list: its entries are homogeneous' do
      tree = { 'hosts' => [{ 'name' => 'a' }, { 'name' => 'b' }] }

      expect(described_class.key_paths(tree)).to eq(['hosts', 'hosts.name'])
    end

    it 'limits the depth: task inventories yield twenty thousand names for nothing' do
      tree = { 'a' => { 'b' => { 'c' => { 'd' => { 'e' => 1 } } } } }

      expect(described_class.key_paths(tree, [], [], depth: 2)).to eq(%w[a a.b])
    end
  end

  describe 'the composition of services' do
    let(:tree) do
      {
        'services' => {
          'worker' => {
            'image' => 'lm:latest',
            'environment' => { 'RAILS_ENV' => 'production', 'DB_HOST' => 'node1' },
            'volumes' => ['/srv/app:/app:ro', { 'source' => 'data', 'target' => '/data' }],
            'ports' => ['5432:5432', { 'published' => 8080, 'target' => 80 }]
          }
        }
      }
    end

    it 'recognises a service-composition file' do
      expect(described_class.compose?('docker-compose.worker.yml', tree)).to be(true)
      expect(described_class.compose?('config/database.yml', { 'production' => {} })).to be(false)
    end

    # Four questions, each of which has cost an incident once: the image, the
    # keys, the mounts, the ports.
    it 'takes the image, the key names, the mounts and the ports' do
      service = described_class.compose_services(tree).first

      expect(service[:service]).to eq('worker')
      expect(service[:image]).to eq('lm:latest')
      expect(service[:env]).to eq(%w[RAILS_ENV DB_HOST])
      expect(service[:mounts]).to eq(['/srv/app:/app', 'data:/data'])
      expect(service[:ports]).to eq(['5432:5432', '8080:80'])
    end

    it 'takes NAMES out of the environment keys: in a service definition the value is the secret' do
      expect(described_class.env_names(['SECRET=пароль', 'MODE=on'])).to eq(%w[SECRET MODE])
    end
  end

  it 'returns nil for an unusable file rather than killing the parse' do
    expect(described_class.parse('config/x.json', '{ не json')).to be_nil
    expect(described_class.parse('config/x.yml', "a:\n- b\n  c: 1\n")).to be_nil
  end
end
