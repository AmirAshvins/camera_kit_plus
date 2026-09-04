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
  s.source_files = 'camera_kit_plus/Sources/camera_kit_plus/**/*.swift'
  s.dependency 'FlutterMacOS'

  s.platform = :osx, '10.15'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
