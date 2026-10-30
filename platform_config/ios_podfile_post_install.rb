# ===== rdlive: REQUIRED by permission_handler on iOS =====
# Without these flags the plugin is compiled WITHOUT the permission code and every request
# silently returns "denied" with no pop-up. (Most common cause of "the pop-up never shows".)
    target.build_configurations.each do |config|
      config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] ||= [
        '$(inherited)',
        'PERMISSION_CAMERA=1',
        'PERMISSION_MICROPHONE=1',
        'PERMISSION_PHOTOS=1',
        'PERMISSION_NOTIFICATIONS=1',
      ]
    end
