# encoding: utf-8
#
# Copyright:: Copyright 2016, Chef Software Inc.
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
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

name 'inspec'
friendly_name "Inspec"
maintainer 'Chef Software, Inc <maintainers@chef.io>'
homepage 'https://github.com/chef/inspec'

license 'Apache-2.0'
license_file '../LICENSE'

# Defaults to C:/opscode/inspec on Windows
# and /opt/inspec on all other platforms.
if windows?
  install_dir "#{default_root}/opscode/#{name}"
else
  install_dir "#{default_root}/#{name}"
end

build_version Omnibus::BuildVersion.semver
build_iteration 1

dependency 'preparation'
dependency 'ruby'
dependency 'rb-readline'

dependency 'inspec'

dependency 'gem-permissions'
dependency 'shebang-cleanup'
dependency 'openssl-customization'
dependency 'version-manifest'
dependency 'clean-static-libs'

package :rpm do
  signing_passphrase ENV["OMNIBUS_RPM_SIGNING_PASSPHRASE"]
end

package :pkg do
  identifier "com.getchef.pkg.inspec"
  signing_identity "Developer ID Installer: Chef Software, Inc. (EU3VF8YLX2)"
end
compress :dmg

package :msi do
  fast_msi true
  upgrade_code "DFCD452F-31E5-4236-ACD1-253F4720250B"
  wix_light_extension "WixUtilExtension"
  signing_identity "F74E1A68005E8A9C465C3D2FF7B41F3988F0EA09", machine_store: true
end

exclude '**/.git'
exclude '**/bundler/git'
