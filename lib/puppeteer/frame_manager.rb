require 'timeout'

class Puppeteer::FrameManager
  include Puppeteer::DebugPrint

  UTILITY_WORLD_NAME = '__puppeteer_utility_world__'

  # @param {!Puppeteer.CDPSession} client
  # @param {!Puppeteer.Page} page
  # @param {boolean} ignoreHTTPSErrors
  # @param {!Puppeteer.TimeoutSettings} timeoutSettings
  def initialize(client, page, ignore_https_errors, timeout_settings)
    @client = client
    @page = page
    @network_manager = Puppeteer::NetworkManager.new(client, ignore_https_errors, self)
    @timeout_settings = timeout_settings

    # @type {!Map<string, !Frame>}
    @frames = {}

    # @type {!Map<number, !ExecutionContext>}
    @context_id_to_context = {}

    # @type {!Set<string>}
    @isolated_worlds = Set.new

    # this._client.on('Page.frameAttached', event => this._onFrameAttached(event.frameId, event.parentFrameId));
    # this._client.on('Page.frameNavigated', event => this._onFrameNavigated(event.frame));
    # this._client.on('Page.navigatedWithinDocument', event => this._onFrameNavigatedWithinDocument(event.frameId, event.url));
    # this._client.on('Page.frameDetached', event => this._onFrameDetached(event.frameId));
    # this._client.on('Page.frameStoppedLoading', event => this._onFrameStoppedLoading(event.frameId));
    # this._client.on('Runtime.executionContextCreated', event => this._onExecutionContextCreated(event.context));
    # this._client.on('Runtime.executionContextDestroyed', event => this._onExecutionContextDestroyed(event.executionContextId));
    # this._client.on('Runtime.executionContextsCleared', event => this._onExecutionContextsCleared());
    # this._client.on('Page.lifecycleEvent', event => this._onLifecycleEvent(event));
  end

  def init
    @client.send_message('Page.enable')
    result = @client.send_message('Page.getFrameTree')
    frame_tree = result['frameTree']
    handle_frame_tree(frame_tree)
    @client.send_message('Page.setLifecycleEventsEnabled', enabled: true)
    @client.send_message('Runtime.enable')
    ensure_isolated_world(UTILITY_WORLD_NAME)
    @network_manager.init
  end

  # @return {!NetworkManager}
  def network_manager
    @network_manager
  end

  class NavigationError < StandardError ; end

  # Temporary implementation instead of LifecycleWatcher#timeoutOrTerminationPromise
  private def with_navigation_timeout(timeout_ms, &block)
    raise ArgymentError.new('block must be provided') if block.nil?

    Timeout.timeout(timeout_ms / 1000.0) do
      block.call
    end
  rescue Timeout::Error
    raise NavigationError("Navigation timeout of #{timeout_ms}ms exceeded")
  end

  # @param frame [Puppeteer::Frame]
  # @param url [String]
  # @param {!{referer?: string, timeout?: number, waitUntil?: string|!Array<string>}=} options
  # @return [Puppeteer::Response]
  def navigate_frame(frame, url, referer: nil, timeout: nil, wait_until: nil)
    assert_no_legacy_navigation_options(wait_until: wait_until)

    navigate_params = {
      url: url,
      referer: referer || @network_manager.extra_http_headers['referer'],
      frameId: frame.id
    }.compact
    option_wait_until = wait_until || ['load']
    option_timeout = timeout || @timeout_settings.navigation_timeout

    #    const watcher = new LifecycleWatcher(this, frame, waitUntil, timeout);
    ensure_new_document_navigation = false
    with_navigation_timeout(option_timeout) do
      result = @client.send_message('Page.navigate', navigate_params)
      loader_id = result['loaderId']
      ensure_new_document_navigation = !!loader_id
      if result['errorText']
        raise NavigationError.new("#{result['errorText']} at #{url}")
      end
    end

    #    let error = await Promise.race([
    #      navigate(this._client, url, referer, frame._id),
    #      watcher.timeoutOrTerminationPromise(),
    #    ]);
    #    if (!error) {
    #      error = await Promise.race([
    #        watcher.timeoutOrTerminationPromise(),
    #        ensureNewDocumentNavigation ? watcher.newDocumentNavigationPromise() : watcher.sameDocumentNavigationPromise(),
    #      ]);
    #    }
    #    watcher.dispose();
    #    if (error)
    #      throw error;
    #    return watcher.navigationResponse();
  end

  #  /**
  #   * @param {!Puppeteer.Frame} frame
  #   * @param {!{timeout?: number, waitUntil?: string|!Array<string>}=} options
  #   * @return {!Promise<?Puppeteer.Response>}
  #   */
  #  async waitForFrameNavigation(frame, options = {}) {
  #    assertNoLegacyNavigationOptions(options);
  #    const {
  #      waitUntil = ['load'],
  #      timeout = this._timeoutSettings.navigationTimeout(),
  #    } = options;
  #    const watcher = new LifecycleWatcher(this, frame, waitUntil, timeout);
  #    const error = await Promise.race([
  #      watcher.timeoutOrTerminationPromise(),
  #      watcher.sameDocumentNavigationPromise(),
  #      watcher.newDocumentNavigationPromise()
  #    ]);
  #    watcher.dispose();
  #    if (error)
  #      throw error;
  #    return watcher.navigationResponse();
  #  }

  #  /**
  #   * @param {!Protocol.Page.lifecycleEventPayload} event
  #   */
  #  _onLifecycleEvent(event) {
  #    const frame = this._frames.get(event.frameId);
  #    if (!frame)
  #      return;
  #    frame._onLifecycleEvent(event.loaderId, event.name);
  #    this.emit(Events.FrameManager.LifecycleEvent, frame);
  #  }

  #  /**
  #   * @param {string} frameId
  #   */
  #  _onFrameStoppedLoading(frameId) {
  #    const frame = this._frames.get(frameId);
  #    if (!frame)
  #      return;
  #    frame._onLoadingStopped();
  #    this.emit(Events.FrameManager.LifecycleEvent, frame);
  #  }

  # @param frame_tree [Hash]
  def handle_frame_tree(frame_tree)
    if frame_tree['frame']['parentId']
      handle_frame_attached(frame_tree['frame']['id'], frame_tree['frame']['parentId'])
    end
    handle_frame_navigated(frame_tree['frame'])
    return if !frame_tree['childFrames']

    frame_tree['childFrames'].each do |child|
      handle_frame_tree(child)
    end
  end

  # @return {!Puppeteer.Page}
  def page
    @page
  end

  # @return {!Frame}
  def main_frame
    @main_frame
  end

  # @return {!Array<!Frame>}
  def frames
    @frames.values
  end

  # @param {!string} frameId
  # @return {?Frame}
  def frame(frame_id)
    @frames[frame_id]
  end

  # /**
  #  * @param {string} frameId
  #  * @param {?string} parentFrameId
  #  */
  # _onFrameAttached(frameId, parentFrameId) {
  #   if (this._frames.has(frameId))
  #     return;
  #   assert(parentFrameId);
  #   const parentFrame = this._frames.get(parentFrameId);
  #   const frame = new Frame(this, this._client, parentFrame, frameId);
  #   this._frames.set(frame._id, frame);
  #   this.emit(Events.FrameManager.FrameAttached, frame);
  # }

  # @param frame_payload [Hash]
  def handle_frame_navigated(frame_payload)
    is_main_frame = !frame_payload['parent_id']
    frame =
      if is_main_frame
        @main_frame
      else
        @frames[frame_payload['id']]
      end

    if !is_main_frame && !frame
      raise ArgumentError.new('We either navigate top level or have old version of the navigated frame')
    end

    # Detach all child frames first.
    if frame
      frame.child_frames.each do |child|
        remove_frame_recursively(child)
      end
    end

    # Update or create main frame.
    if is_main_frame
      if frame
        # Update frame id to retain frame identity on cross-process navigation.
        @frames.delete(frame.id)
        frame.id = frame_payload['id']
      else
        # Initial main frame navigation.
        frame = Puppeteer::Frame.new(self, @client, nil, frame_payload['id'])
      end
      @frames[frame_payload['id']] = frame
      @main_frame = frame
    end

    # Update frame payload.
    frame.navigated(frame_payload);

    handle_frame_manager_frame_navigated(frame)
  end

  private def handle_frame_manager_frame_navigated(frame)
  end

  # @param name [String]
  def ensure_isolated_world(name)
    return if @isolated_worlds.include?(name)
    @isolated_worlds << name

    @client.send_message('Page.addScriptToEvaluateOnNewDocument',
      source: '//# sourceURL=__puppeteer_evaluation_script__',
      worldName: name,
    )
    frames.each do |frame|
      begin
        @client.send_message('Page.createIsolatedWorld',
          frameId: frame.id,
          grantUniveralAccess: true,
          worldName: name,
        )
      rescue => err
        debug_print(err)
      end
    end
  end

  # @param frame_id [String]
  # @param url [String]
  def handle_frame_navigated_within_document(frame_id, url)
    frame = @frames[frame_id]
    return if !frame
    frame.navigated_within_document(url)
    handle_frame_manager_frame_navigated_within_document(frame)
    handle_frame_manager_frame_navigated(frame)
  end

  private def handle_frame_manager_frame_navigated_within_document(frame)
  end

  private def handle_frame_manager_frame_navigated(frame)
  end

  # @param frame_id [String]
  def handle_frame_detached(frame_id)
    frame = @frames[frame_id]
    if frame
      remove_frame_recursively(frame)
    end
  end

  # _onExecutionContextCreated(contextPayload) {
  #   const frameId = contextPayload.auxData ? contextPayload.auxData.frameId : null;
  #   const frame = this._frames.get(frameId) || null;
  #   let world = null;
  #   if (frame) {
  #     if (contextPayload.auxData && !!contextPayload.auxData['isDefault']) {
  #       world = frame._mainWorld;
  #     } else if (contextPayload.name === UTILITY_WORLD_NAME && !frame._secondaryWorld._hasContext()) {
  #       // In case of multiple sessions to the same target, there's a race between
  #       // connections so we might end up creating multiple isolated worlds.
  #       // We can use either.
  #       world = frame._secondaryWorld;
  #     }
  #   }
  #   if (contextPayload.auxData && contextPayload.auxData['type'] === 'isolated')
  #     this._isolatedWorlds.add(contextPayload.name);
  #   /** @type {!ExecutionContext} */
  #   const context = new ExecutionContext(this._client, contextPayload, world);
  #   if (world)
  #     world._setContext(context);
  #   this._contextIdToContext.set(contextPayload.id, context);
  # }

  # @param {number} executionContextId
  def handle_execution_context_destroyed(execution_context_id)
    context = @context_id_to_context[execution_context_id]
    return if !context
    @context_id_to_context.delete(execution_context_id)
    if context.world
      context.world.context = nil
    end
  end

  def handle_execution_contexts_cleared
    @context_id_to_context.values.each do |context|
      if context.world
        context.world.context = nil
      end
    end
    @context_id_to_context.clear
  end

  def execution_context_by_id(context_id)
    context = @context_id_to_context[context_id]
    if !context
      raise "INTERNAL ERROR: missing context with id = #{context_id}"
    end
    return context
  end

  # @param {!Frame} frame
  private def remove_frame_recursively(frame)
    frame.child_frames.each do |child|
      remove_frame_recursively(child)
    end
    frame.detach
    @frames.delete(frame.id)
    handle_frame_manager_frame_detached(frame)
  end

  private def handle_frame_manager_frame_detached(frame)
  end

  private def assert_no_legacy_navigation_options(wait_until:)
    if wait_until == 'networkidle'
      raise ArgumentError.new('ERROR: "networkidle" option is no longer supported. Use "networkidle2" instead')
    end
  end
end
