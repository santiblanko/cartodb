require 'spec_helper_min'
require 'support/helpers'
require 'helpers/feature_flag_helper'
require 'carto/dbdirect/certificate_manager'

module TestCertificateManager
  module_function

  @crl = []

  def generate_certificate(config:, username:, passphrase:, validity_days:, server_ca:)
    [
      {
        client_key: mocked('key', username, passphrase),
        client_crt: mocked('crt', username, validity_days, config),
        server_ca: server_ca ? mocked('cacrt', config) : nil
      },
      mocked('arn', username, validity_days, config)
    ]
  end

  def revoke_certificate(config:, arn:, reason: 'UNSPECIFIED')
    @crl << mocked('crt', arn, reason, config)
  end

  def _crl
    @crl
  end

  class <<self
    private
    def mocked(name, *args)
      "#{name} for #{args.join('_')}"
    end
  end
end

describe Carto::Api::Public::DbdirectCertificatesController do
  include_context 'users helper'
  include HelperMethods
  include FeatureFlagHelper

  before(:all) do
    host! "#{@user1.username}.localhost.lan"
    @feature_flag = FactoryGirl.create(:feature_flag, name: 'dbdirect', restricted: true)
    @config = {
      certificates: {
        ca_arn: "the-ca-arn",
        maximum_validity_days: 300,
        aws_access_key_id: 'the_aws_key',
        aws_secret_key: 'the_aws_secret',
        aws_region: 'the_aws_region'
      }
    }.with_indifferent_access
  end

  after(:all) do
    @feature_flag.destroy
  end

  describe '#create' do
    before(:each) do
      @params = { api_key: @user1.api_key }
      Carto::DbdirectCertificate.stubs(:certificate_manager).returns(TestCertificateManager)
    end

    after(:each) do
      Carto::DbdirectCertificate.delete_all
    end

    it 'needs authentication for certificate creation' do
      params = {
        name: 'cert_name'
      }
      post_json api_v4_dbdirect_certificates_create_url(params) do |response|
        expect(response.status).to eq(401)
      end
    end

    it 'needs the feature flag for certificate creation' do
        params = {
          name: 'cert_name',
          api_key: @user1.api_key
        }
        with_feature_flag @user1, 'dbdirect', false do
          post_json api_v4_dbdirect_certificates_create_url(params) do |response|
            expect(response.status).to eq(403)
          end
        end
    end

    it 'creates certificates without password ips or validity' do
      params = {
        name: 'cert_name',
        api_key: @user1.api_key
      }
      with_feature_flag @user1, 'dbdirect', true do
        Cartodb.with_config dbdirect: @config do
          post_json api_v4_dbdirect_certificates_create_url(params) do |response|
            expect(response.status).to eq(201)
            expect(response.body[:client_crt]).to eq %{crt for user00000001_300_#{@config['certificates']}}
            expect(response.body[:client_key]).to eq %{key for user00000001_}
            expect(response.body[:server_ca]).to be_nil
            expect(response.body[:name]).to eq 'cert_name'
            cert_id = response.body[:id]
            expect(cert_id).not_to be_empty
            cert = Carto::DbdirectCertificate.find(cert_id)
            expect(cert.user.id).to eq @user1.id
            expect(cert.name).to eq 'cert_name'
            expect(cert.arn).to eq %{arn for user00000001_300_#{@config['certificates']}}
          end
        end
      end
    end

    it 'names certificates after the user if no name is provided' do
      params = {
        api_key: @user1.api_key
      }
      with_feature_flag @user1, 'dbdirect', true do
        Cartodb.with_config dbdirect: @config do
          post_json api_v4_dbdirect_certificates_create_url(params) do |response|
            expect(response.status).to eq(201)
            expect(response.body[:client_crt]).to eq %{crt for user00000001_300_#{@config['certificates']}}
            expect(response.body[:client_key]).to eq %{key for user00000001_}
            expect(response.body[:server_ca]).to be_nil
            expect(response.body[:name]).to eq @user1.username
            cert_id = response.body[:id]
            expect(cert_id).not_to be_empty
            cert = Carto::DbdirectCertificate.find(cert_id)
            expect(cert.user.id).to eq @user1.id
            expect(cert.name).to eq @user1.username
          end
        end
      end
    end

    it 'avoids certificate name clashes adding a suffix' do
      params = {
        name: 'cert_name',
        api_key: @user1.api_key
      }
      with_feature_flag @user1, 'dbdirect', true do
        Cartodb.with_config dbdirect: @config do
          post_json api_v4_dbdirect_certificates_create_url(params) do |response|
            expect(response.status).to eq(201)
            expect(response.body[:name]).to eq 'cert_name'
            cert_id = response.body[:id]
            cert = Carto::DbdirectCertificate.find(cert_id)
            expect(cert.user.id).to eq @user1.id
            expect(cert.name).to eq 'cert_name'
          end
          post_json api_v4_dbdirect_certificates_create_url(params) do |response|
            expect(response.status).to eq(201)
            expect(response.body[:name]).to eq 'cert_name_1'
            cert_id = response.body[:id]
            cert = Carto::DbdirectCertificate.find(cert_id)
            expect(cert.user.id).to eq @user1.id
            expect(cert.name).to eq 'cert_name_1'
          end
          post_json api_v4_dbdirect_certificates_create_url(params) do |response|
            expect(response.status).to eq(201)
            expect(response.body[:name]).to eq 'cert_name_2'
            cert_id = response.body[:id]
            cert = Carto::DbdirectCertificate.find(cert_id)
            expect(cert.user.id).to eq @user1.id
            expect(cert.name).to eq 'cert_name_2'
          end
        end
      end
    end

    it 'creates certificates with password, ips and validity' do
      params = {
        name: 'cert_name',
        pass: 'the_password',
        ips: '100.200.30.40',
        validity: 150,
        api_key: @user1.api_key
      }
      with_feature_flag @user1, 'dbdirect', true do
        Cartodb.with_config dbdirect: @config do
          post_json api_v4_dbdirect_certificates_create_url(params) do |response|
            expect(response.status).to eq(201)
            expect(response.body[:client_crt]).to eq %{crt for user00000001_150_#{@config['certificates']}}
            expect(response.body[:client_key]).to eq %{key for user00000001_the_password}
            expect(response.body[:server_ca]).to be_nil
            expect(response.body[:name]).to eq 'cert_name'
            cert_id = response.body[:id]
            expect(cert_id).not_to be_empty
            cert = Carto::DbdirectCertificate.find(cert_id)
            expect(cert.user.id).to eq @user1.id
            expect(cert.name).to eq 'cert_name'
            expect(cert.arn).to eq %{arn for user00000001_150_#{@config['certificates']}}
          end
        end
      end
    end

    it 'creates certificates and downloads server ca' do
      params = {
        name: 'cert_name',
        ips: '100.200.30.40',
        validity: 200,
        api_key: @user1.api_key,
        server_ca: true
      }
      with_feature_flag @user1, 'dbdirect', true do
        Cartodb.with_config dbdirect: @config do
          post_json api_v4_dbdirect_certificates_create_url(params) do |response|
            expect(response.status).to eq(201)
            expect(response.body[:client_crt]).to eq %{crt for user00000001_200_#{@config['certificates']}}
            expect(response.body[:client_key]).to eq %{key for user00000001_}
            expect(response.body[:server_ca]).to eq %{cacrt for #{@config['certificates']}}
            expect(response.body[:name]).to eq 'cert_name'
            cert_id = response.body[:id]
            expect(cert_id).not_to be_empty
            cert = Carto::DbdirectCertificate.find(cert_id)
            expect(cert.user.id).to eq @user1.id
            expect(cert.name).to eq 'cert_name'
            expect(cert.arn).to eq %{arn for user00000001_200_#{@config['certificates']}}
          end
        end
      end
    end
  end

  describe '#destroy' do
    before(:each) do
      @params = { api_key: @user1.api_key }
      Carto::DbdirectCertificate.stubs(:certificate_manager).returns(TestCertificateManager)
      @certificate_data, @dbdirect_certificate = Carto::DbdirectCertificate.generate(
        user: @user1,
        name:'cert_name',
        validity_days: 365
      )
    end

    after(:each) do
      Carto::DbdirectCertificate.delete_all
    end

    it 'needs authentication for certificate revocation' do
      params = {
        id: @dbdirect_certificate.id,
      }
      arn = @dbdirect_certificate.arn
      delete_json api_v4_dbdirect_certificates_destroy_url(params) do |response|
        expect(response.status).to eq(401)
        expect(Carto::DbdirectCertificate.find_by_id(@dbdirect_certificate.id)).not_to be_nil
        expect(TestCertificateManager._crl).not_to include %{crt for #{arn}_UNSPECIFIED_#{@config['certificates']}}
      end
    end

    it 'needs the feature flag for certificate revocation' do
      params = {
        id: @dbdirect_certificate.id,
        api_key: @user1.api_key
      }
      arn = @dbdirect_certificate.arn
      with_feature_flag @user1, 'dbdirect', false do
        delete_json api_v4_dbdirect_certificates_destroy_url(params) do |response|
          expect(response.status).to eq(403)
          expect(Carto::DbdirectCertificate.find_by_id(@dbdirect_certificate.id)).not_to be_nil
          expect(TestCertificateManager._crl).not_to include %{crt for #{arn}_UNSPECIFIED_#{@config['certificates']}}
        end
      end
    end

    it 'cannot revoke certificates owned by other users' do
      host! "#{@user2.username}.localhost.lan"
      params = {
        id: @dbdirect_certificate.id,
        api_key: @user2.api_key
      }
      arn = @dbdirect_certificate.arn
      with_feature_flag @user2, 'dbdirect', false do
        delete_json api_v4_dbdirect_certificates_destroy_url(params) do |response|
          expect(response.status).to eq(401)
          expect(Carto::DbdirectCertificate.find_by_id(@dbdirect_certificate.id)).not_to be_nil
          expect(TestCertificateManager._crl).not_to include %{crt for #{arn}_UNSPECIFIED_#{@config['certificates']}}
        end
      end
      host! "#{@user1.username}.localhost.lan"
    end

    it 'revokes certificates' do
      params = {
        id: @dbdirect_certificate.id,
        api_key: @user1.api_key
      }
      arn = @dbdirect_certificate.arn
      with_feature_flag @user1, 'dbdirect', true do
        Cartodb.with_config dbdirect: @config do
          delete_json api_v4_dbdirect_certificates_destroy_url(params) do |response|
            expect(response.status).to eq(200)
            expect(Carto::DbdirectCertificate.find_by_id(@dbdirect_certificate.id)).to be_nil
            expect(TestCertificateManager._crl).to include %{crt for #{arn}_UNSPECIFIED_#{@config['certificates']}}
            expect(response.body[:name]).to eq 'cert_name'
            expect(response.body[:id]).to eq @dbdirect_certificate.id
          end
        end
      end
    end
  end

  describe '#list' do
    before(:each) do
      @params = { api_key: @user1.api_key }
      Carto::DbdirectCertificate.stubs(:certificate_manager).returns(TestCertificateManager)
      @certificate_data1, @dbdirect_certificate1 = Carto::DbdirectCertificate.generate(
        user: @user1,
        name:'cert_1',
        validity_days: 365
      )
      @certificate_data2, @dbdirect_certificate2 = Carto::DbdirectCertificate.generate(
        user: @user1,
        name:'cert_2',
        validity_days: 300,
        ips: '100.200.30.40'
      )
    end

    after(:each) do
      Carto::DbdirectCertificate.delete_all
    end

    it 'needs authentication for listing certificates' do
      params = {
      }
      get_json api_v4_dbdirect_certificates_list_url(params) do |response|
        expect(response.status).to eq(401)
      end
    end

    it 'needs the feature flag for listing certificates' do
      params = {
        api_key: @user1.api_key
      }
      with_feature_flag @user1, 'dbdirect', false do
        get_json api_v4_dbdirect_certificates_list_url(params) do |response|
          expect(response.status).to eq(403)
        end
      end
    end

    it 'lists certificates' do
      params = {
        api_key: @user1.api_key
      }
      with_feature_flag @user1, 'dbdirect', true do
        Cartodb.with_config dbdirect: @config do
          get_json api_v4_dbdirect_certificates_list_url(params) do |response|
            expect(response.status).to eq(200)
            expect(response.body.size).to eq 2
            cert1_info = response.body.find { |c| c['id'] == @dbdirect_certificate1.id }
            cert2_info = response.body.find { |c| c['id'] == @dbdirect_certificate2.id }
            expect(cert1_info).not_to be_nil
            expect(cert2_info).not_to be_nil
            expect(cert1_info['name']).to eq @dbdirect_certificate1.name
            expect(cert1_info['ips']).to eq @dbdirect_certificate1.ips
            expect(cert1_info['expiration']).to eq @dbdirect_certificate1.expiration.to_datetime.rfc3339
            expect(cert2_info['name']).to eq @dbdirect_certificate2.name
            expect(cert2_info['ips']).to eq @dbdirect_certificate2.ips
            expect(cert2_info['expiration']).to eq @dbdirect_certificate2.expiration.to_datetime.rfc3339
          end
        end
      end
    end
  end

  describe '#show' do
    before(:each) do
      @params = { api_key: @user1.api_key }
      Carto::DbdirectCertificate.stubs(:certificate_manager).returns(TestCertificateManager)
      @certificate_data, @dbdirect_certificate = Carto::DbdirectCertificate.generate(
        user: @user1,
        name:'cert_name',
        validity_days: 365
      )
    end

    after(:each) do
      Carto::DbdirectCertificate.delete_all
    end

    it 'needs authentication to show a certificate' do
      params = {
        id: @dbdirect_certificate.id,
      }
      get_json api_v4_dbdirect_certificates_show_url(params) do |response|
        expect(response.status).to eq(401)
      end
    end

    it 'needs the feature flag to show a certificate' do
      params = {
        id: @dbdirect_certificate.id,
        api_key: @user1.api_key
      }
      with_feature_flag @user1, 'dbdirect', false do
        get_json api_v4_dbdirect_certificates_show_url(params) do |response|
          expect(response.status).to eq(403)
        end
      end
    end

    it 'cannot show certificates owned by other users' do
      host! "#{@user2.username}.localhost.lan"
      params = {
        id: @dbdirect_certificate.id,
        api_key: @user2.api_key
      }
      with_feature_flag @user2, 'dbdirect', false do
        get_json api_v4_dbdirect_certificates_show_url(params) do |response|
          expect(response.status).to eq(401)
        end
      end
      host! "#{@user1.username}.localhost.lan"
    end

    it 'shows certificates' do
      params = {
        id: @dbdirect_certificate.id,
        api_key: @user1.api_key
      }
      with_feature_flag @user1, 'dbdirect', true do
        Cartodb.with_config dbdirect: @config do
          get_json api_v4_dbdirect_certificates_show_url(params) do |response|
            expect(response.status).to eq(200)
            expect(response.body[:id]).to eq @dbdirect_certificate.id
            expect(response.body[:name]).to eq @dbdirect_certificate.name
            expect(response.body[:ips]).to eq @dbdirect_certificate.ips
            expect(response.body[:expiration]).to eq @dbdirect_certificate.expiration.to_datetime.rfc3339
          end
        end
      end
    end
  end
end
