#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint camera_kit_plus.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'camera_kit_plus'
  s.version          = '0.0.50'
  s.summary          = 'Camera Kit Plus barcode and OCR'
  s.description      = <<-DESC
Camera Kit Plus — barcode scanning and OCR for Flutter.
                       DESC
  s.homepage         = 'https://github.com/MahmoodBakhshayesh/camera_kit_plus'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Abomis' => 'info@abomis.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'camera_kit_plus/Sources/camera_kit_plus/**/*.swift'
  s.dependency       'Flutter'
  s.platform         = :ios, '13.0'

  # Flutter.framework does not contain an i386 slice.
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }

  s.swift_version = '5.0'

  s.resource_bundles = {
    'camera_kit_plus_privacy' => ['camera_kit_plus/Sources/camera_kit_plus/PrivacyInfo.xcprivacy']
  }
end
