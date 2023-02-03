require 'tmpdir'

# https://github.com/puppeteer/puppeteer/blob/main/src/node/Launcher.ts
module Puppeteer::Launcher
  class Chrome
    def initialize(project_root:, preferred_revision:, is_puppeteer_core:)
      @project_root = project_root
      @preferred_revision = preferred_revision
      @is_puppeteer_core = is_puppeteer_core
    end

    # @param {!(Launcher.LaunchOptions & Launcher.ChromeArgOptions & Launcher.BrowserOptions)=} options
    # @return {!Promise<!Browser>}
    def launch(options = {})
      @chrome_arg_options = ChromeArgOptions.new(options)
      @launch_options = LaunchOptions.new(options)
      @browser_options = BrowserOptions.new(options)

      chrome_arguments =
        if !@launch_options.ignore_default_args
          default_args(options).to_a
        elsif @launch_options.ignore_default_args.is_a?(Enumerable)
          default_args(options).reject do |arg|
            @launch_options.ignore_default_args.include?(arg)
          end.to_a
        else
          @chrome_arg_options.args.dup
        end

      if chrome_arguments.none? { |arg| arg.start_with?('--remote-debugging-') }
        if @launch_options.pipe?
          chrome_arguments << '--remote-debugging-pipe'
        else
          chrome_arguments << "--remote-debugging-port=#{@chrome_arg_options.debugging_port}"
        end
      end

      user_data_dir = chrome_arguments.find { |arg| arg.start_with?('--user-data-dir') }
      if user_data_dir
        user_data_dir = user_data_dir.split('=').last
        unless File.exist?(user_data_dir)
          raise ArgumentError.new("Chrome user data dir not found at '#{user_data_dir}'")
        end
        using_temp_user_data_dir = false
      else
        user_data_dir = Dir.mktmpdir('puppeteer_dev_chrome_profile-', ENV['PUPPETEER_TMP_DIR'])
        chrome_arguments << "--user-data-dir=#{user_data_dir}"
        using_temp_user_data_dir = true
      end

      chrome_executable =
        if @launch_options.channel
          executable_path_for_channel(@launch_options.channel.to_s)
        else
          @launch_options.executable_path || fallback_executable_path
        end
      use_pipe = chrome_arguments.include?('--remote-debugging-pipe')
      runner = Puppeteer::BrowserRunner.new(
        false,
        chrome_executable,
        chrome_arguments,
        user_data_dir,
        using_temp_user_data_dir,
      )
      runner.start(
        handle_SIGHUP: @launch_options.handle_SIGHUP?,
        handle_SIGTERM: @launch_options.handle_SIGTERM?,
        handle_SIGINT: @launch_options.handle_SIGINT?,
        dumpio: @launch_options.dumpio?,
        env: @launch_options.env,
        pipe: use_pipe,
      )

      browser =
        begin
          connection = runner.setup_connection(
            use_pipe: use_pipe,
            timeout: @launch_options.timeout,
            slow_mo: @browser_options.slow_mo,
            preferred_revision: @preferred_revision,
          )

          Puppeteer::Browser.create(
            product: product,
            connection: connection,
            context_ids: [],
            ignore_https_errors: @browser_options.ignore_https_errors?,
            default_viewport: @browser_options.default_viewport,
            process: runner.proc,
            close_callback: -> { runner.close },
            target_filter_callback: nil,
            is_page_target_callback: nil,
          )
        rescue
          runner.kill
          raise
        end

      begin
        browser.wait_for_target(
          predicate: ->(target) { target.type == 'page' },
          timeout: @launch_options.timeout,
        )
      rescue
        browser.close
        raise
      end

      browser
    end

    class DefaultArgs
      include Enumerable

      # @param options [Launcher::ChromeArgOptions]
      def initialize(chrome_arg_options)
        # See https://github.com/GoogleChrome/chrome-launcher/blob/main/docs/chrome-flags-for-tools.md
        chrome_arguments = [
          '--allow-pre-commit-input',
          '--disable-background-networking',
          '--disable-background-timer-throttling',
          '--disable-backgrounding-occluded-windows',
          '--disable-breakpad',
          '--disable-client-side-phishing-detection',
          '--disable-component-extensions-with-background-pages',
          '--disable-component-update',
          '--disable-default-apps',
          '--disable-dev-shm-usage',
          '--disable-extensions',
          # AcceptCHFrame disabled because of crbug.com/1348106.
          '--disable-features=Translate,BackForwardCache,AcceptCHFrame,MediaRouter,OptimizationHints',
          '--disable-hang-monitor',
          '--disable-ipc-flooding-protection',
          '--disable-popup-blocking',
          '--disable-prompt-on-repost',
          '--disable-renderer-backgrounding',
          '--disable-sync',
          '--enable-automation',
          # TODO(sadym): remove '--enable-blink-features=IdleDetection' once
          # IdleDetection is turned on by default.
          '--enable-blink-features=IdleDetection',
          '--enable-features=NetworkServiceInProcess2',
          '--export-tagged-pdf',
          '--force-color-profile=srgb',
          '--metrics-recording-only',
          '--no-first-run',
          '--password-store=basic',
          '--use-mock-keychain',
        ]

        if chrome_arg_options.user_data_dir
          chrome_arguments << "--user-data-dir=#{chrome_arg_options.user_data_dir}"
        end

        if chrome_arg_options.devtools?
          chrome_arguments << '--auto-open-devtools-for-tabs'
        end

        if chrome_arg_options.headless?
          chrome_arguments.concat([
            '--headless',
            '--hide-scrollbars',
            '--mute-audio',
          ])
        end

        # helper for Docker
        # https://github.com/puppeteer/puppeteer/blob/main/docs/troubleshooting.md#setting-up-chrome-linux-sandbox
        if %w[1 true].include?(ENV['PUPPETEER_RUBY_NO_SANDBOX'])
          ['--no-sandbox', '--disable-setuid-sandbox'].each do |arg|
            unless chrome_arguments.include?(arg)
              chrome_arguments << arg
            end
          end
        end

        if chrome_arg_options.args.all? { |arg| arg.start_with?('-') }
          chrome_arguments << 'about:blank'
        end

        chrome_arguments.concat(chrome_arg_options.args)

        @chrome_arguments = chrome_arguments
      end

      def each(&block)
        @chrome_arguments.each do |opt|
          block.call(opt)
        end
      end
    end

    # @return [DefaultArgs]
    def default_args(options = nil)
      DefaultArgs.new(ChromeArgOptions.new(options || {}))
    end

    # @return {string}
    def executable_path(channel: nil)
      if channel
        executable_path_for_channel(channel.to_s)
      else
        fallback_executable_path
      end
    end

    private def fallback_executable_path
      executable_path_for_channel('chrome')
    end

    CHROMIUM_CHANNELS = {
      windows: {
        'chrome' => "#{ENV['PROGRAMFILES']}\\Google\\Chrome\\Application\\chrome.exe",
        'chrome-beta' => "#{ENV['PROGRAMFILES']}\\Google\\Chrome Beta\\Application\\chrome.exe",
        'chrome-canary' => "#{ENV['PROGRAMFILES']}\\Google\\Chrome SxS\\Application\\chrome.exe",
        'chrome-dev' => "#{ENV['PROGRAMFILES']}\\Google\\Chrome Dev\\Application\\chrome.exe",
        'msedge' => "#{ENV['PROGRAMFILES(X86)']}\\Microsoft\\Edge\\Application\\msedge.exe",
      },
      darwin: {
        'chrome' => '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
        'chrome-beta' => '/Applications/Google Chrome Beta.app/Contents/MacOS/Google Chrome Beta',
        'chrome-canary' => '/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary',
        'chrome-dev' => '/Applications/Google Chrome Dev.app/Contents/MacOS/Google Chrome Dev',
        'msedge' => '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
      },
      linux: {
        'chrome' => -> {
          Puppeteer::ExecutablePathFinder.new(
            'google-chrome-stable',
            'google-chrome',
            'chrome',
            'chromium-freeworld',
            'chromium-browser',
            'chromium',
          ).find_first
        },
        'chrome-beta' => '/opt/google/chrome-beta/chrome',
        'chrome-dev' => '/opt/google/chrome-unstable/chrome',
      },
    }.freeze

    # @param channel [String]
    private def executable_path_for_channel(channel)
      chrome_path_map =
        if Puppeteer.env.windows?
          CHROMIUM_CHANNELS[:windows]
        elsif Puppeteer.env.darwin?
          CHROMIUM_CHANNELS[:darwin]
        else
          CHROMIUM_CHANNELS[:linux]
        end

      chrome_path = chrome_path_map[channel]
      unless chrome_path
        raise ArgumentError.new("Invalid channel: '#{channel}'. Allowed channel is #{chrome_path_map.keys}")
      end

      if chrome_path.is_a?(Proc)
        chrome_path = chrome_path.call
      end

      if !chrome_path || !File.exist?(chrome_path)
        raise "#{channel} is not installed on this system.\nExpected path: #{chrome_path}"
      end

      chrome_path
    end

    def product
      'chrome'
    end
  end
end
