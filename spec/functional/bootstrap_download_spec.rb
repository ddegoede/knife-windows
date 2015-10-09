#
# Author:: Adam Edwards (<adamed@opscode.com>)
# Copyright:: Copyright (c) 2012 Opscode, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
# implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'spec_helper'
require 'tmpdir'

# These test cases exercise the Knife::Windows knife plugin's ability
# to download a bootstrap msi as part of the bootstrap process on
# Windows nodes. The test modifies the Windows batch file generated
# from an erb template in the plugin source in order to enable execution
# of only the download functionality contained in the bootstrap template.
# The test relies on knowledge of the fields of the template itself and
# also on knowledge of the contents and structure of the Windows batch
# file generated by the template.
#
# Note that if the bootstrap template changes substantially, the tests
# should fail and will require re-implementation. If such changes
# occur, the bootstrap code should be refactored to explicitly expose
# the download funcitonality separately from other tasks to make the
# test more robust.
describe 'Knife::Windows::Core msi download functionality for knife Windows winrm bootstrap template' do

  before(:all) do
    # Since we're always running 32-bit Ruby, fix the
    # PROCESSOR_ARCHITECTURE environment variable.

    if ENV["PROCESSOR_ARCHITEW6432"]
      ENV["PROCESSOR_ARCHITECTURE"] = ENV["PROCESSOR_ARCHITEW6432"]
    end

    # All file artifacts from this test will be written into this directory
    @temp_directory = Dir.mktmpdir("bootstrap_test")

    # Location to which the download script will be modified to write
    # the downloaded msi
    @local_file_download_destination = "#{@temp_directory}/chef-client-latest.msi"

    source_code_directory = File.dirname(__FILE__)
    @template_file_path ="#{source_code_directory}/../../lib/chef/knife/bootstrap/windows-chef-client-msi.erb"
  end

  after(:all) do
    # Clear the temp directory upon exit
    if Dir.exists?(@temp_directory)
      FileUtils::remove_dir(@temp_directory)
    end
  end

  describe "running on any version of the Windows OS", :windows_only do
    let(:mock_bootstrap_context) { Chef::Knife::Core::WindowsBootstrapContext.new({ }, nil, { :knife => {} }) }
    let(:mock_winrm) { Chef::Knife::Winrm.new }

    before do
      # Stub the bootstrap context and prevent config related sections
      # from being populated, i.e. chef installation and first chef
      # run sections
      allow(mock_bootstrap_context).to receive(:validation_key).and_return("echo.validation_key")
      allow(mock_bootstrap_context).to receive(:secret).and_return("echo.encrypted_data_bag_secret")
      allow(mock_bootstrap_context).to receive(:config_content).and_return("echo.config_content")
      allow(mock_bootstrap_context).to receive(:start_chef).and_return("echo.echo start_chef_command")
      allow(mock_bootstrap_context).to receive(:run_list).and_return("echo.run_list")
      allow(mock_bootstrap_context).to receive(:install_chef).and_return("echo.echo install_chef_command")

      # Change the directories where bootstrap files will be created
      allow(mock_bootstrap_context).to receive(:bootstrap_directory).and_return(@temp_directory.gsub(::File::SEPARATOR, ::File::ALT_SEPARATOR))
      allow(mock_bootstrap_context).to receive(:local_download_path).and_return(@local_file_download_destination.gsub(::File::SEPARATOR, ::File::ALT_SEPARATOR))

      # Prevent password prompt during bootstrap process
      allow(mock_winrm).to receive(:get_password).and_return(nil)
      allow(Chef::Knife::Winrm).to receive(:new).and_return(mock_winrm)

      allow(Chef::Knife::Core::WindowsBootstrapContext).to receive(:new).and_return(mock_bootstrap_context)
      Chef::Config[:knife] = {:winrm_transport => 'plaintext', :chef_node_name => 'foo.example.com', :winrm_authentication_protocol => 'negotiate'}
    end

    it "downloads the chef-client MSI from the default location during winrm bootstrap" do
      run_download_scenario
    end

    context "when provided a custom msi_url to fetch from" do
      let(:mock_bootstrap_context) { Chef::Knife::Core::WindowsBootstrapContext.new(
        { :msi_url => "file:///C:/Windows/System32/xcopy.exe" }, nil, { :knife => {} }) }
      it "downloads the chef-client MSI from a custom path during winrm bootstrap" do
        run_download_scenario
      end
    end

     context "when provided a custom msi_url with space in path to fetch from" do
      let(:mock_bootstrap_context) { Chef::Knife::Core::WindowsBootstrapContext.new(
        { :msi_url => "file:///C:/Program Files/Windows NT/Accessories/wordpad.exe" }, nil, { :knife => {} }) }
      it "downloads the chef-client MSI from a custom path with spaces during winrm bootstrap" do
        run_download_scenario
      end
    end
  end

  def download_succeeded?
    File.exists?(@local_file_download_destination) && ! File.zero?(@local_file_download_destination)
  end

  # Remove file artifacts generated by individual test cases
  def clean_test_case
    if File.exists?(@local_file_download_destination)
      File.delete(@local_file_download_destination)
    end
  end

  def run_download_scenario
    clean_test_case

    winrm_bootstrapper = Chef::Knife::BootstrapWindowsWinrm.new([ "127.0.0.1" ])

    if chef_gte_12?
      winrm_bootstrapper.client_builder = instance_double("Chef::Knife::Bootstrap::ClientBuilder", :run => nil, :client_path => nil)
    elsif chef_lt_12?
      allow(File).to receive(:exist?).with(File.expand_path(Chef::Config[:validation_key])).and_return(true)
    end

    allow(winrm_bootstrapper).to receive(:wait_for_remote_response)
    allow(winrm_bootstrapper).to receive(:validate_options)
    winrm_bootstrapper.config[:template_file] = @template_file_path
    winrm_bootstrapper.config[:run_list] = []
    # Execute the commands locally that would normally be executed via WinRM
    allow(winrm_bootstrapper).to receive(:run_command) do |command|
      system(command)
    end

    winrm_bootstrapper.run

    # Download should succeed
    expect(download_succeeded?).to be true
  end
end

describe "bootstrap_install_command functionality through WinRM protocol", :if_chef_11 => true, :chef_lt_12_5_only => true do
  context "bootstrap_install_command option is not specified" do
    let(:bootstrap) { Chef::Knife::BootstrapWindowsWinrm.new([]) }
    before do
      @template_input = sample_data('win_template_unrendered.txt')
      @template_output = sample_data('win_template_rendered_without_bootstrap_install_command.txt')
    end

    it "bootstrap_install_command option is not rendered in the windows-chef-client-msi.erb template as its value is nil" do
      expect(bootstrap.send(:render_template,@template_input)).to eq(
        @template_output)
    end
  end

  context "bootstrap_install_command option is specified" do
    let(:bootstrap) { Chef::Knife::BootstrapWindowsWinrm.new(['--bootstrap-install-command', 'chef-client -o recipe[cbk1::rec2]']) }
    before do
      bootstrap.config[:bootstrap_install_command] = "chef-client -o recipe[cbk1::rec2]"
      @template_input = sample_data('win_template_unrendered.txt')
      @template_output = sample_data('win_template_rendered_with_bootstrap_install_command.txt')
    end

    it "bootstrap_install_command option is rendered in the windows-chef-client-msi.erb template" do
      expect(bootstrap.send(:render_template,@template_input)).to eq(
        @template_output)
    end

    after do
      bootstrap.config.delete(:bootstrap_install_command)
      Chef::Config[:knife].delete(:bootstrap_install_command)
    end
  end
end

describe "bootstrap_install_command functionality through SSH protocol", :if_chef_11 => true, :chef_lt_12_5_only => true do
  context "bootstrap_install_command option is not specified" do
    let(:bootstrap) { Chef::Knife::BootstrapWindowsSsh.new([]) }
    before do
      @template_input = sample_data('win_template_unrendered.txt')
      @template_output = sample_data('win_template_rendered_without_bootstrap_install_command.txt')
    end

    it "bootstrap_install_command option is not rendered in the windows-chef-client-msi.erb template as its value is nil" do
      expect(bootstrap.send(:render_template,@template_input)).to eq(
        @template_output)
    end
  end

  context "bootstrap_install_command option is specified" do
    let(:bootstrap) { Chef::Knife::BootstrapWindowsSsh.new(['--bootstrap-install-command', 'chef-client -o recipe[cbk1::rec2]']) }
    before do
      bootstrap.config[:bootstrap_install_command] = "chef-client -o recipe[cbk1::rec2]"
      @template_input = sample_data('win_template_unrendered.txt')
      @template_output = sample_data('win_template_rendered_with_bootstrap_install_command.txt')
    end

    it "bootstrap_install_command option is rendered in the windows-chef-client-msi.erb template" do
      expect(bootstrap.send(:render_template,@template_input)).to eq(
        @template_output)
    end

    after do
      bootstrap.config.delete(:bootstrap_install_command)
      Chef::Config[:knife].delete(:bootstrap_install_command)
    end
  end
end
