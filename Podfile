# Uncomment the next line to define a global platform for your project
# platform :ios, '9.0'

source 'https://github.com/CocoaPods/Specs.git'

target 'Waveform-iOS' do
  # Comment the next line if you don't want to use dynamic frameworks
  use_frameworks!

  # Pods for Waveform-iOS

  platform :ios, '8.4'
  pod 'MobileVLCKit', '~>3.3.0'
end

target 'Waveform-macOS' do
  # Comment the next line if you don't want to use dynamic frameworks
  use_frameworks!

  # Pods for Waveform-macOS
  
  platform :macos, '10.9'
  pod 'VLCKit', '~>3.3.0'

end

target 'WaveformWidgets' do
  # Comment the next line if you don't want to use dynamic frameworks
  use_frameworks!

  # Pods for WaveformWidgets

end

post_install do |installer|
  vlc_header = File.join(
    installer.sandbox.root,
    'VLCKit/VLCKit.framework/Headers/VLCMediaThumbnailer.h'
  )

  if File.exist?(vlc_header)
    contents = File.read(vlc_header)

    old = <<~HEADER
      #import <Foundation/Foundation.h>
      #if TARGET_OS_IPHONE
      # import <CoreGraphics/CoreGraphics.h>
      #endif
    HEADER

    new = <<~HEADER
      #import <Foundation/Foundation.h>
      #import <CoreGraphics/CoreGraphics.h>
    HEADER

    unless contents.include?(new)
      contents = contents.sub(old, new)
      File.write(vlc_header, contents)
    end
  end
end

pod 'swift-vibrant'




