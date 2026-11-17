Pod::Spec.new do |s|
  s.name           = 'TripodCamera'
  s.version        = '0.1.0'
  s.summary        = 'Tripod native camera (AVFoundation) exposed through the Expo Modules API'
  s.description    = s.summary
  s.license        = 'MIT'
  s.author         = 'Tripod'
  s.homepage       = 'https://github.com/zenxol/tripod-mobile'
  s.platforms      = { :ios => '16.4' }
  # Swift 5 language mode: the capture session is driven from its own serial queue,
  # which Swift 6 strict concurrency checking would reject without extra annotations.
  s.swift_version  = '5.9'
  s.source         = { git: 'https://github.com/zenxol/tripod-mobile.git' }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'
  s.frameworks = 'AVFoundation'

  s.source_files = '**/*.{h,m,swift}'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES'
  }
end
