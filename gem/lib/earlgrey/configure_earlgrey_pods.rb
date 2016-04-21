#
#  Copyright 2016 Google Inc.
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.

# global export for unqualified use in Pods file
def configure_for_earlgrey *args
  EarlGrey.configure_for_earlgrey *args
end

module EarlGrey
  class << self
    attr_accessor :swift, :carthage
    attr_reader :project_name, :test_target, :test_target_name, :scheme_file, :user_project

    def path_for xcode_file, ext
      return xcode_file if File.exist? xcode_file

      path = File.join(Dir.pwd, File.basename(xcode_file, '.*') + ext)
      path ? path : nil
    end

    def configure_for_earlgrey(installer, project_name, test_target_name, scheme_file)
      puts ("Checking and Updating #{project_name} for EarlGrey.").blue
      pods_project = installer ? installer.pods_project : true
      project_file = path_for project_name, '.xcodeproj'

      fail 'No test target provided' unless test_target_name

      if pods_project.nil? || project_file.nil?
        fail "The target's xcodeproj file could not be found. Please check if "\
      'the correct PROJECT_NAME is being passed in the Podfile. Current '\
      "PROJECT_NAME is: #{project_name}"
      end

      @project_name = project_name
      @test_target_name = test_target_name
      @scheme_file = File.basename(scheme_file, '.*') + '.xcscheme'
      @user_project = Xcodeproj::Project.open(project_file)
      all_targets = user_project.targets
      @test_target = all_targets.find { |target| target.name == test_target_name }
      fail "Unable to find target: #{test_target_name}. Targets are: #{all_targets.map &:name}" unless test_target

      # Add a Test Action to the User Project Scheme.
      scheme = modify_scheme_for_actions

      # Add a Copy Files Build Phase for EarlGrey.framework to embed it into the app under test.
      # carthage uses carthage copy-frameworks instead of a copy files build phase.
      add_earlgrey_copy_files_script unless carthage

      # Add header/framework search paths for carthage
      add_carthage_search_paths

      # Adds BridgingHeader.h, EarlGrey.swift and sets bridging header.
      copy_swift_files

      save_earlgrey_scheme_changes(scheme) unless scheme.nil?

      puts ("EarlGrey setup complete. You can use the Test Target : #{test_target_name} "\
            "for EarlGrey testing.").blue
    end

    # Scheme changes to ensure that EarlGrey is correctly loaded before main() is called.
    def modify_scheme_for_actions
      scheme_filename = scheme_file
      # If you do not pass on a scheme name, we set it to the project name itself.
      if scheme_filename.to_s == ''
        scheme_filename = project_name
      end

      xcdata_dir = Xcodeproj::XCScheme.user_data_dir(user_project.path)
      unless File.exist?(File.join(xcdata_dir, scheme_filename).to_s)
        xcdata_dir = Xcodeproj::XCScheme.shared_data_dir(user_project.path)
      end

      unless File.exist?(File.join(xcdata_dir, scheme_filename).to_s)
        fail "The required scheme \"" + scheme_filename +"\" could not be found."
        ' Please ensure that the required scheme file exists within your'\
        ' project directory.'
      end
      scheme = Xcodeproj::XCScheme.new File.join(xcdata_dir, scheme_filename)
      test_action_key = 'DYLD_INSERT_LIBRARIES'
      test_action_value = '@executable_path/EarlGrey.framework/EarlGrey'
      if not scheme.test_action.xml_element.to_s.include? test_action_value
        scheme =
            add_environment_variables_to_test_action_scheme(scheme_filename,
                                                            scheme,
                                                            test_action_key,
                                                            test_action_value)
      end

      return scheme
    end

    # Load the EarlGrey framework when the app binary is loaded by
    # the dynamic loader, before the main() method is called.
    def add_environment_variables_to_test_action_scheme(scheme_filename,
                                                        scheme,
                                                        test_action_key,
                                                        test_action_value)
      test_action = scheme.test_action
      if (scheme.test_action.xml_element.to_s.include? test_action_key) ||
          (scheme.launch_action.xml_element.to_s.include? test_action_key)
        puts ("\n//////////////////// EARLGREY SCHEME ISSUE ////////////////////\n"\
      "EarlGrey failed to modify the Test Action part of the scheme: " + scheme_filename + "\n"\
      + "for one of following reasons:\n\n"\
      "1) DYLD_INSERT_LIBRARIES is already defined under Environment Variables of\n"\
      "the Test Action.\n"\
      "2) Run Action's environment variables are used for Test Action.\n\n"\
      "To ensure correct functioning of EarlGrey, please manually add the\n"\
      "following under Test Action's Environment Variables of the scheme:" + scheme_filename + "\n"\
      "Environment Variables or EarlGrey's location will not be found.\n"\
      "Name: DYLD_INSERT_LIBRARIES\n"\
      "Value: @executable_path/EarlGrey.framework/EarlGrey\n"\
      "///////////////////////////////////////////////////////////////\n\n").yellow
        return
      end
      puts "Adding EarlGrey Framework Location as an Environment Variable "
      "in the App Project's Test Target's Scheme Test Action."

      # Check if the test action uses the run action's environment variables and arguments.
      launch_action_env_args_present = false
      if (scheme.test_action.xml_element.to_s.include? 'shouldUseLaunchSchemeArgsEnv') &&
          ((scheme.launch_action.xml_element.to_s.include? '<EnvironmentVariables>') ||
              (scheme.launch_action.xml_element.to_s.include? '<CommandLineArguments>'))
        launch_action_env_args_present = true
      end

      test_action_isEnabled = 'YES'
      test_action.should_use_launch_scheme_args_env = false

      # If no environment variables are set, then create the element itself.
      unless scheme.test_action.xml_element.to_s.include? '<EnvironmentVariables>'
        scheme.test_action.xml_element.add_element('EnvironmentVariables')
      end

      # If Launch Action Arguments are present and none are present in the test
      # action, then please add them in.
      if (scheme.launch_action.xml_element.to_s.include? '<CommandLineArguments>') &&
          !(scheme.test_action.xml_element.to_s.include? '<CommandLineArguments>')
        scheme.test_action.xml_element.add_element('CommandLineArguments')
      end

      # Create a new environment variable and add it to the Environment Variables.
      test_action_env_vars = scheme.test_action.xml_element.elements['EnvironmentVariables']
      test_action_args = scheme.test_action.xml_element.elements['CommandLineArguments']

      earl_grey_environment_variable = REXML::Element.new 'EnvironmentVariable'
      earl_grey_environment_variable.attributes['key'] = test_action_key
      earl_grey_environment_variable.attributes['value'] = test_action_value
      earl_grey_environment_variable.attributes['isEnabled'] = test_action_isEnabled
      test_action_env_vars.add_element(earl_grey_environment_variable)

      # If any environment variables or arguments were being used in the test action by
      # being copied from the launch (run) action then copy them over to the test action
      # along with the EarlGrey environment variable.
      if launch_action_env_args_present
        launch_action_env_vars = scheme.launch_action.xml_element.elements['EnvironmentVariables']
        launch_action_args = scheme.launch_action.xml_element.elements['CommandLineArguments']

        # Add in the Environment Variables
        launch_action_env_vars.elements.each('EnvironmentVariable') do |launch_action_env_var|
          environment_variable = REXML::Element.new 'EnvironmentVariable'
          environment_variable.attributes['key'] = launch_action_env_var.attributes['key']
          environment_variable.attributes['value'] = launch_action_env_var.attributes['value']
          environment_variable.attributes['isEnabled'] = launch_action_env_var.attributes['isEnabled']
          test_action_env_vars.add_element(environment_variable)
        end

        #Add in the Arguments
        launch_action_args.elements.each('CommandLineArgument') do |launch_action_arg|
          argument = REXML::Element.new 'CommandLineArgument'
          argument.attributes['argument'] = launch_action_arg.attributes['argument']
          argument.attributes['isEnabled'] = launch_action_arg.attributes['isEnabled']
          test_action_args.add_element(argument)
        end

      end
      scheme.test_action = test_action
      scheme
    end

    # Adds EarlGrey.framework to products group. Returns file ref.
    def add_earlgrey_product
      return @add_earlgrey_product if @add_earlgrey_product
      framework_path = carthage ? '${SRCROOT}/Carthage/Build/iOS/EarlGrey.framework' :
          '${SRCROOT}/Pods/EarlGrey/EarlGrey-1.0.0/EarlGrey.framework'

      framework_ref = user_project.products_group.files.find { |f| f.path == framework_path }
      return @add_earlgrey_product = framework_ref if framework_ref

      framework_ref = user_project.products_group.new_file(framework_path)
      framework_ref.source_tree = 'SRCROOT'

      @add_earlgrey_product = framework_ref
    end

    # Generates a copy files build phase to embed the EarlGrey framework into
    # the app under test.
    def add_earlgrey_copy_files_script
      earlgrey_copy_files_phase_name = 'EarlGrey Copy Files'
      earlgrey_copy_files_exists = false
      test_target.copy_files_build_phases.each do |copy_files_phase|
        if copy_files_phase.name == earlgrey_copy_files_phase_name
          earlgrey_copy_files_exists = true
        end
      end

      unless earlgrey_copy_files_exists
        new_copy_files_phase = test_target.new_copy_files_build_phase(earlgrey_copy_files_phase_name)
        new_copy_files_phase.dst_path = '$(TEST_HOST)/../'
        new_copy_files_phase.dst_subfolder_spec = '0'

        file_ref = add_earlgrey_product
        build_file = new_copy_files_phase.add_file_reference(file_ref, true)
        build_file.settings = {'ATTRIBUTES' => ['CodeSignOnCopy']}
        user_project.save
      end
    end

    FRAMEWORK_SEARCH_PATHS = 'FRAMEWORK_SEARCH_PATHS'
    HEADER_SEARCH_PATHS = 'HEADER_SEARCH_PATHS'

    def add_carthage_search_paths
      return unless carthage
      carthage_build_ios = '$(SRCROOT)/Carthage/Build/iOS'
      carthage_headers_ios = '$(SRCROOT)/Carthage/Build/iOS/**'

      test_target.build_configurations.each do |config|
        settings = config.build_settings
        settings[FRAMEWORK_SEARCH_PATHS] = Array(settings[FRAMEWORK_SEARCH_PATHS])
        unless settings[FRAMEWORK_SEARCH_PATHS].include?(carthage_build_ios)
          settings[FRAMEWORK_SEARCH_PATHS] << carthage_build_ios
        end

        settings[HEADER_SEARCH_PATHS] = Array(settings[HEADER_SEARCH_PATHS])
        unless settings[HEADER_SEARCH_PATHS].include?(carthage_headers_ios)
          settings[HEADER_SEARCH_PATHS] << carthage_headers_ios
        end
      end

      user_project.save
    end

    SWIFT_OBJC_BRIDGING_HEADER = 'SWIFT_OBJC_BRIDGING_HEADER'

    def copy_swift_files
      return unless swift
      bridge_path = '$(TARGET_NAME)/BridgingHeader.h'

      test_target.build_configurations.each do |config|
        settings = config.build_settings
        settings[SWIFT_OBJC_BRIDGING_HEADER] = bridge_path
      end

      user_project.save

      src_root = File.join(__dir__, 'files')
      dst_root = File.join(Dir.pwd, test_target_name)
      fail "Missing target folder #{dst_root}" unless File.exist? dst_root

      src_header_name = 'BridgingHeader.h'
      src_header = File.join(src_root, src_header_name)
      fail 'Bundled header missing' unless File.exist? src_header
      dst_header = File.join(dst_root, src_header_name)

      src_swift_name = 'EarlGrey.swift'
      src_swift = File.join(src_root, src_swift_name)
      fail 'Bundled swift missing' unless File.exist? src_swift
      dst_swift = File.join(dst_root, src_swift_name)

      FileUtils.copy src_header, dst_header
      FileUtils.copy src_swift, dst_swift

      test_target_group = user_project.main_group.children.find { |g| g.display_name == test_target_name }
      fail "Test target group not found! #{test_target_group}" unless test_target_group

      # Add files to testing target group otherwise Xcode can't read them.
      new_files = [src_header_name, src_swift_name]
      existing_files = test_target_group.children.map(&:display_name)

      new_files.each do |file|
        next if existing_files.include? file
        test_target_group.new_reference(file)
      end

      # Add EarlGrey.swift to sources build phase
      existing_sources = test_target.source_build_phase.files.map(&:display_name)
      unless existing_sources.include? src_swift_name
        earlgrey_swift_file_ref = test_target_group.files.find { |f| f.display_name == src_swift_name }
        fail 'EarlGrey.swift not found in testing target' unless earlgrey_swift_file_ref
        test_target.source_build_phase.add_file_reference earlgrey_swift_file_ref
      end

      # Link Binary With Libraries - frameworks_build_phase - Add EarlGrey.framework
      earlgrey_framework = 'EarlGrey.framework'
      existing_frameworks = test_target.frameworks_build_phase.files.map(&:display_name)
      unless existing_frameworks.include? earlgrey_framework
        framework_ref = add_earlgrey_product
        test_target.frameworks_build_phase.add_file_reference framework_ref
      end

      # Add shell script phase
      shell_script_name = 'Carthage copy-frameworks Run Script'
      unless test_target.shell_script_build_phases.map(&:name).include?(shell_script_name)
        shell_script = test_target.new_shell_script_build_phase shell_script_name
        shell_script.shell_path = '/bin/bash'
        shell_script.shell_script = '/usr/local/bin/carthage copy-frameworks'
        shell_script.input_paths = ['$(SRCROOT)/Carthage/Build/iOS/EarlGrey.framework']
      end

      user_project.save
    end

    # Save the scheme changes. This is done here to prevent any irreversible changes in case
    # of an exception being thrown.
    def save_earlgrey_scheme_changes(scheme)
      scheme.save!
    end
  end
end
