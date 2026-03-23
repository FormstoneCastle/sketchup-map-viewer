# 3D Map Viewer — Kiosk Mode for SketchUp 2017 (Windows)
# Hides all SketchUp UI, shows only the 3D viewport + navigator panel.
# Click "Exit Viewer" or type MapViewer.restore in the Ruby Console to restore.

module MapViewer

  @saved_state = {}
  @win32_ready = false

  # ---- Windows API setup ----
  def self.init_win32
    return if @win32_ready
    require 'fiddle'

    user32 = Fiddle.dlopen('user32.dll')

    @fn = {}
    funcs = {
      'FindWindowA'       => [[Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP], Fiddle::TYPE_LONG],
      'GetForegroundWindow' => [[], Fiddle::TYPE_LONG],
      'GetWindow'         => [[Fiddle::TYPE_LONG, Fiddle::TYPE_INT], Fiddle::TYPE_LONG],
      'GetMenu'           => [[Fiddle::TYPE_LONG], Fiddle::TYPE_LONG],
      'SetMenu'           => [[Fiddle::TYPE_LONG, Fiddle::TYPE_LONG], Fiddle::TYPE_LONG],
      'DrawMenuBar'       => [[Fiddle::TYPE_LONG], Fiddle::TYPE_INT],
      'GetWindowLongA'    => [[Fiddle::TYPE_LONG, Fiddle::TYPE_INT], Fiddle::TYPE_LONG],
      'SetWindowLongA'    => [[Fiddle::TYPE_LONG, Fiddle::TYPE_INT, Fiddle::TYPE_LONG], Fiddle::TYPE_LONG],
      'SetWindowPos'      => [[Fiddle::TYPE_LONG, Fiddle::TYPE_LONG, Fiddle::TYPE_INT,
                               Fiddle::TYPE_INT, Fiddle::TYPE_INT, Fiddle::TYPE_INT,
                               Fiddle::TYPE_INT], Fiddle::TYPE_INT],
      'GetSystemMetrics'  => [[Fiddle::TYPE_INT], Fiddle::TYPE_INT],
      'ShowWindow'        => [[Fiddle::TYPE_LONG, Fiddle::TYPE_INT], Fiddle::TYPE_INT],
      'GetWindowRect'     => [[Fiddle::TYPE_LONG, Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT],
      'GetWindowTextA'    => [[Fiddle::TYPE_LONG, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT], Fiddle::TYPE_INT],
      'GetClassNameA'     => [[Fiddle::TYPE_LONG, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT], Fiddle::TYPE_INT],
      'GetTopWindow'      => [[Fiddle::TYPE_LONG], Fiddle::TYPE_LONG],
      'IsWindowVisible'   => [[Fiddle::TYPE_LONG], Fiddle::TYPE_INT],
      'SetForegroundWindow' => [[Fiddle::TYPE_LONG], Fiddle::TYPE_INT],
    }
    funcs.each do |name, (args, ret)|
      @fn[name] = Fiddle::Function.new(user32[name], args, ret)
    end

    @win32_ready = true
  rescue => e
    puts "Win32 init failed: #{e.message}"
    @win32_ready = false
  end

  # ---- Win32 helpers ----
  def self.get_window_text(hwnd)
    buf = "\0" * 512
    len = @fn['GetWindowTextA'].call(hwnd, buf, 512)
    buf[0, len]
  end

  def self.get_class_name(hwnd)
    buf = "\0" * 256
    len = @fn['GetClassNameA'].call(hwnd, buf, 256)
    buf[0, len]
  end

  # Walk child windows of a parent
  def self.enum_children(parent_hwnd)
    children = []
    child = @fn['GetTopWindow'].call(parent_hwnd)
    while child != 0
      children << child
      # Use GetWindow with GW_HWNDNEXT (2) — more reliable than GetNextWindow
      next_child = @fn['GetWindow'].call(child, 2)
      break if next_child == child # safety
      child = next_child
    end
    children
  end

  # Find the main SketchUp window using the model title
  def self.find_sketchup_window
    # Build expected title from SketchUp's model info
    model = Sketchup.active_model
    # SketchUp window title is typically: "filename - SketchUp Make 2017" or similar
    # Try FindWindowA with the exact title
    title_text = nil

    # First, let's find it by enumerating from the desktop
    desktop_child = @fn['GetTopWindow'].call(0)
    candidates = []

    count = 0
    hwnd = desktop_child
    while hwnd != 0 && count < 500
      title = get_window_text(hwnd)
      if title.include?("SketchUp") && @fn['IsWindowVisible'].call(hwnd) != 0
        cls = get_class_name(hwnd)
        menu = @fn['GetMenu'].call(hwnd)
        puts "  Found: '#{title}' class='#{cls}' menu=#{menu} hwnd=#{hwnd}"
        candidates << { hwnd: hwnd, title: title, cls: cls, menu: menu }
      end
      hwnd = @fn['GetWindow'].call(hwnd, 2) # GW_HWNDNEXT
      count += 1
    end

    # Prefer the window with a menu bar (the main app window)
    main = candidates.find { |c| c[:menu] != 0 }
    main ||= candidates.first

    if main
      puts "Using window: '#{main[:title]}' hwnd=#{main[:hwnd]}"
      return main[:hwnd]
    end

    # Last resort: try FindWindowA with nil class
    puts "Warning: Enumeration found nothing. Trying FindWindowA..."
    hwnd = @fn['FindWindowA'].call(nil, nil)
    puts "FindWindowA fallback: hwnd=#{hwnd} title='#{get_window_text(hwnd)}'"
    hwnd
  end

  # Apply (or re-apply) kiosk mode — hides chrome, fullscreens viewport
  def self.apply_kiosk
    return unless @win32_ready && @hwnd

    # Hide all children except the viewport
    if @saved_state[:hidden_children]
      @saved_state[:hidden_children].each do |child|
        next if child[:hwnd] == @saved_state[:viewport_hwnd]
        @fn['ShowWindow'].call(child[:hwnd], 0) # SW_HIDE
      end
    end

    # Also re-enumerate in case SketchUp recreated child windows
    children = enum_children(@hwnd)
    children.each do |child|
      next if child == @saved_state[:viewport_hwnd]
      if @fn['IsWindowVisible'].call(child) != 0
        cls = get_class_name(child)
        # Don't hide the viewport or our WebDialog
        next if child == @saved_state[:viewport_hwnd]
        @fn['ShowWindow'].call(child, 0) # SW_HIDE
      end
    end

    # Remove menu bar
    @fn['SetMenu'].call(@hwnd, 0)
    @fn['DrawMenuBar'].call(@hwnd)

    # Borderless
    style = @fn['GetWindowLongA'].call(@hwnd, GWL_STYLE)
    new_style = style & ~WS_CAPTION & ~WS_THICKFRAME & ~WS_BORDER
    @fn['SetWindowLongA'].call(@hwnd, GWL_STYLE, new_style)

    # Fullscreen
    @fn['SetWindowPos'].call(@hwnd, 0, 0, 0, @screen_w, @screen_h, SWP_FRAMECHANGED | SWP_NOZORDER)

    # Resize viewport to fill
    if @saved_state[:viewport_hwnd]
      @fn['SetWindowPos'].call(@saved_state[:viewport_hwnd], 0, 0, 0, @screen_w, @screen_h, SWP_NOZORDER)
    end
  end

  # ---- Constants ----
  GWL_STYLE     = -16
  WS_CAPTION    = 0x00C00000
  WS_THICKFRAME = 0x00040000
  WS_BORDER     = 0x00800000
  SWP_FRAMECHANGED = 0x0020
  SWP_NOZORDER  = 0x0004
  SM_CXSCREEN   = 0
  SM_CYSCREEN   = 1

  def self.launch
    init_win32

    model = Sketchup.active_model
    ro = model.rendering_options

    # Save rendering state
    @saved_state[:rendering] = {
      "DrawHorizon" => ro["DrawHorizon"],
      "DrawGround"  => ro["DrawGround"],
    }
    ro["DrawHorizon"] = true
    ro["DrawGround"] = true

    if @win32_ready
      puts "--- Searching for SketchUp window ---"

      # Find the REAL SketchUp main window
      @hwnd = find_sketchup_window

      # Save window style and position
      @saved_state[:style] = @fn['GetWindowLongA'].call(@hwnd, GWL_STYLE)
      rect = "\0" * 16
      @fn['GetWindowRect'].call(@hwnd, rect)
      @saved_state[:rect] = rect.unpack('l4')

      # Save menu bar handle
      @saved_state[:menu] = @fn['GetMenu'].call(@hwnd)

      # Find and save visible child windows
      children = enum_children(@hwnd)
      @saved_state[:hidden_children] = []
      puts "--- Child windows (#{children.length}) ---"

      children.each do |child|
        if @fn['IsWindowVisible'].call(child) != 0
          cls = get_class_name(child)
          cr = "\0" * 16
          @fn['GetWindowRect'].call(child, cr)
          l, t, r, b = cr.unpack('l4')
          w = r - l
          h = b - t
          puts "  child hwnd=#{child} class='#{cls}' size=#{w}x#{h}"
          @saved_state[:hidden_children] << { hwnd: child, cls: cls, w: w, h: h }
        end
      end

      # Find the viewport — it's the largest child window
      sorted = @saved_state[:hidden_children].sort_by { |c| -(c[:w] * c[:h]) }
      viewport = sorted.first
      if viewport
        puts "Viewport (largest child): class='#{viewport[:cls]}' size=#{viewport[:w]}x#{viewport[:h]}"
        @saved_state[:viewport_hwnd] = viewport[:hwnd]
      end

      # Save screen size
      @screen_w = @fn['GetSystemMetrics'].call(SM_CXSCREEN)
      @screen_h = @fn['GetSystemMetrics'].call(SM_CYSCREEN)

      # Find and hide the Ruby Console first
      desktop_child = @fn['GetTopWindow'].call(0)
      hwnd = desktop_child
      count = 0
      while hwnd != 0 && count < 500
        title = get_window_text(hwnd)
        if title.include?("Ruby Console") && @fn['IsWindowVisible'].call(hwnd) != 0
          @saved_state[:console_hwnd] = hwnd
          @fn['ShowWindow'].call(hwnd, 0) # SW_HIDE
          break
        end
        hwnd = @fn['GetWindow'].call(hwnd, 2)
        count += 1
      end

      # Apply kiosk mode, then re-apply on a timer to beat SketchUp's layout manager
      apply_kiosk
      UI.start_timer(0.3, false) { apply_kiosk }
      UI.start_timer(0.6, false) { apply_kiosk }
      UI.start_timer(1.0, false) { apply_kiosk }

      # Keep re-applying every 2 seconds for 10 seconds to make sure it sticks
      @kiosk_timer_count = 0
      @kiosk_timer = UI.start_timer(2.0, true) {
        @kiosk_timer_count += 1
        if @kiosk_timer_count > 5
          UI.stop_timer(@kiosk_timer)
        else
          apply_kiosk
        end
      }
    end

    # Show navigator after kiosk mode settles
    UI.start_timer(1.2, false) { show_navigator }
  end

  def self.show_navigator
    if @dlg && @dlg.visible?
      @dlg.close
    end

    @dlg = UI::WebDialog.new("3D Map", false, "MapNav", 260, 400, 20, 60, false)

    html = <<-HTML
    <!DOCTYPE html>
    <html>
    <head>
    <style>
      * { box-sizing: border-box; margin: 0; padding: 0; }
      body {
        font-family: Segoe UI, Tahoma, sans-serif;
        background: #0d1117;
        color: #e0e0e0;
        padding: 14px;
        user-select: none;
      }
      h2 {
        text-align: center;
        color: #00d4ff;
        font-size: 15px;
        margin-bottom: 6px;
        letter-spacing: 2px;
        text-transform: uppercase;
      }
      .counter {
        text-align: center;
        font-size: 11px;
        color: #556;
        margin-bottom: 10px;
      }
      .nav-row {
        display: flex;
        gap: 6px;
        margin-bottom: 10px;
      }
      .nav-btn {
        flex: 1;
        padding: 12px 8px;
        border: 1px solid #00d4ff;
        background: #0a1628;
        color: #00d4ff;
        font-size: 13px;
        font-weight: bold;
        cursor: pointer;
        border-radius: 3px;
        letter-spacing: 1px;
        transition: all 0.15s;
      }
      .nav-btn:hover { background: #132744; }
      .nav-btn:active { background: #00d4ff; color: #0a1628; }
      .scene-list {
        list-style: none;
        max-height: 260px;
        overflow-y: auto;
      }
      .scene-list li {
        padding: 10px 12px;
        margin-bottom: 3px;
        background: #0a1628;
        border: 1px solid #1a2a4a;
        border-radius: 3px;
        cursor: pointer;
        font-size: 13px;
        transition: all 0.15s;
        white-space: nowrap;
        overflow: hidden;
        text-overflow: ellipsis;
      }
      .scene-list li:hover {
        background: #132744;
        border-color: #00d4ff;
        padding-left: 16px;
      }
      .scene-list li.active {
        background: #00d4ff;
        color: #0a1628;
        font-weight: bold;
        border-color: #00d4ff;
      }
      .scene-list::-webkit-scrollbar { width: 4px; }
      .scene-list::-webkit-scrollbar-track { background: transparent; }
      .scene-list::-webkit-scrollbar-thumb { background: #1a2a4a; border-radius: 2px; }
      .speed-row {
        display: flex;
        align-items: center;
        gap: 8px;
        margin-bottom: 12px;
        font-size: 11px;
        color: #556;
      }
      .speed-row input {
        flex: 1;
        accent-color: #00d4ff;
      }
      .speed-label {
        min-width: 30px;
        text-align: right;
        color: #00d4ff;
        font-size: 11px;
      }
      .no-scenes {
        text-align: center;
        color: #445;
        padding: 30px 10px;
        font-style: italic;
        font-size: 12px;
      }
    </style>
    </head>
    <body>
      <h2 ondblclick="doAction('exit')" title="Double-click to exit kiosk mode">3D Map</h2>
      <div class="counter" id="counter"></div>
      <div class="nav-row">
        <button class="nav-btn" onclick="doAction('prev')">&laquo; PREV</button>
        <button class="nav-btn" onclick="doAction('next')">NEXT &raquo;</button>
      </div>
      <div class="speed-row">
        <span>Speed:</span>
        <input type="range" id="speed" min="0" max="80" value="5"
               oninput="updateSpeed(this.value)">
        <span class="speed-label" id="speedVal">0.5s</span>
      </div>
      <ul class="scene-list" id="sceneList"></ul>

      <script>
        function doAction(cmd) {
          window.location = 'skp:action@' + cmd;
        }
        function goToScene(index) {
          window.location = 'skp:goto@' + index;
        }
        document.addEventListener('keydown', function(e) {
          if (e.key === 'Escape') { doAction('exit'); }
        });
        function updateSpeed(val) {
          var sec = (val / 10).toFixed(1);
          document.getElementById('speedVal').textContent = sec + 's';
          window.location = 'skp:speed@' + sec;
        }
        function setScenes(names, activeIndex, total) {
          var list = document.getElementById('sceneList');
          var counter = document.getElementById('counter');
          if (total === 0) {
            list.innerHTML = '<li class="no-scenes">No locations defined.</li>';
            counter.textContent = '';
            return;
          }
          counter.textContent = 'Location ' + (activeIndex + 1) + ' of ' + total;
          var html = '';
          for (var i = 0; i < names.length; i++) {
            var cls = (i === activeIndex) ? ' class="active"' : '';
            html += '<li' + cls + ' onclick="goToScene(' + i + ')"';
            html += ' title="' + names[i] + '">' + names[i] + '</li>';
          }
          list.innerHTML = html;
          var activeEl = list.querySelector('.active');
          if (activeEl) activeEl.scrollIntoView({block: 'nearest'});
        }
      </script>
    </body>
    </html>
    HTML

    @dlg.set_html(html)
    @transition_time = 0.5

    refresh = Proc.new {
      model = Sketchup.active_model
      pages = model.pages
      names = pages.map { |p| p.name.gsub("'", "\\'").gsub('"', '&quot;') }
      active_idx = pages.to_a.index(pages.selected_page) || 0
      total = pages.length
      names_js = total > 0 ? "['" + names.join("','") + "']" : "[]"
      @dlg.execute_script("setScenes(#{names_js}, #{active_idx}, #{total})")
    }

    @dlg.add_action_callback("action") do |_dlg, param|
      model = Sketchup.active_model
      pages = model.pages

      case param
      when "next"
        next if pages.length == 0
        idx = (pages.to_a.index(pages.selected_page) || 0)
        target = pages.to_a[(idx + 1) % pages.length]
        target.transition_time = @transition_time
        model.options["PageOptions"]["TransitionTime"] = @transition_time
        pages.selected_page = target
        UI.start_timer(0.1, false) { refresh.call }

      when "prev"
        next if pages.length == 0
        idx = (pages.to_a.index(pages.selected_page) || 0)
        target = pages.to_a[(idx - 1) % pages.length]
        target.transition_time = @transition_time
        model.options["PageOptions"]["TransitionTime"] = @transition_time
        pages.selected_page = target
        UI.start_timer(0.1, false) { refresh.call }

      when "exit"
        restore
      end
    end

    @dlg.add_action_callback("goto") do |_dlg, param|
      model = Sketchup.active_model
      pages = model.pages
      idx = param.to_i
      if idx >= 0 && idx < pages.length
        target = pages.to_a[idx]
        target.transition_time = @transition_time
        model.options["PageOptions"]["TransitionTime"] = @transition_time
        pages.selected_page = target
        UI.start_timer(0.1, false) { refresh.call }
      end
    end

    @dlg.add_action_callback("speed") do |_dlg, param|
      @transition_time = param.to_f
      # Apply to all pages and model options immediately
      model = Sketchup.active_model
      model.options["SlideshowOptions"]["SlideTime"] = @transition_time
      model.pages.each { |p| p.transition_time = @transition_time }
    end

    @dlg.show
    UI.start_timer(0.5, false) { refresh.call }

    # Auto-refresh scene list every 3 seconds (picks up renames, adds, deletes)
    @refresh_timer = UI.start_timer(3.0, true) {
      if @dlg && @dlg.visible?
        refresh.call
      else
        UI.stop_timer(@refresh_timer) rescue nil
      end
    }

    # Remove the WebDialog title bar via Win32
    UI.start_timer(0.3, false) { strip_dialog_titlebar }
  end

  # Find the WebDialog window and remove its title bar
  def self.strip_dialog_titlebar
    return unless @win32_ready

    # Find the dialog window by title "3D Map"
    desktop_child = @fn['GetTopWindow'].call(0)
    hwnd = desktop_child
    count = 0
    while hwnd != 0 && count < 500
      title = get_window_text(hwnd)
      if title == "3D Map" && @fn['IsWindowVisible'].call(hwnd) != 0
        @saved_state[:dlg_hwnd] = hwnd

        # Save original style
        style = @fn['GetWindowLongA'].call(hwnd, GWL_STYLE)
        @saved_state[:dlg_style] = style

        # Get current position/size
        rect = "\0" * 16
        @fn['GetWindowRect'].call(hwnd, rect)
        l, t, r, b = rect.unpack('l4')
        w = r - l
        h = b - t

        # Remove title bar but keep border for a clean edge
        new_style = style & ~WS_CAPTION
        @fn['SetWindowLongA'].call(hwnd, GWL_STYLE, new_style)
        @fn['SetWindowPos'].call(hwnd, 0, l, t - 30, w, h + 30, SWP_FRAMECHANGED | SWP_NOZORDER)
        break
      end
      hwnd = @fn['GetWindow'].call(hwnd, 2)
      count += 1
    end
  end

  # ---- Restore SketchUp to normal ----
  def self.restore
    # Stop the repeating kiosk timer
    UI.stop_timer(@kiosk_timer) if @kiosk_timer rescue nil
    UI.stop_timer(@refresh_timer) if @refresh_timer rescue nil
    @kiosk_timer = nil
    @refresh_timer = nil

    @dlg.close if @dlg && @dlg.visible?

    if @win32_ready && @hwnd
      # Restore menu bar
      if @saved_state[:menu] && @saved_state[:menu] != 0
        @fn['SetMenu'].call(@hwnd, @saved_state[:menu])
        @fn['DrawMenuBar'].call(@hwnd)
      end

      # Restore window style
      if @saved_state[:style]
        @fn['SetWindowLongA'].call(@hwnd, GWL_STYLE, @saved_state[:style])
      end

      # Restore window position
      if @saved_state[:rect]
        l, t, r, b = @saved_state[:rect]
        @fn['SetWindowPos'].call(@hwnd, 0, l, t, r - l, b - t, SWP_FRAMECHANGED | SWP_NOZORDER)
      end

      # Show all hidden children
      if @saved_state[:hidden_children]
        @saved_state[:hidden_children].each do |child|
          next if child[:hwnd] == @saved_state[:viewport_hwnd]
          @fn['ShowWindow'].call(child[:hwnd], 5) # SW_SHOW
        end
      end

      # Show Ruby Console
      if @saved_state[:console_hwnd]
        @fn['ShowWindow'].call(@saved_state[:console_hwnd], 5) # SW_SHOW
      end
    end

    puts "SketchUp UI restored."
  end
end

# Launch kiosk mode
MapViewer.launch
