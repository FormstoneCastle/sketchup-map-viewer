# Scene Navigator for SketchUp 2017
# Paste this into the Ruby Console, or load via Plugins folder.

module SceneNavigator
  def self.show
    # Close existing dialog if open
    if @dlg && @dlg.visible?
      @dlg.close
    end

    @dlg = UI::WebDialog.new("Scene Navigator", false, "SceneNav", 320, 500, 100, 100, true)

    html = <<-HTML
    <!DOCTYPE html>
    <html>
    <head>
    <style>
      * { box-sizing: border-box; margin: 0; padding: 0; }
      body {
        font-family: Segoe UI, Tahoma, sans-serif;
        background: #1a1a2e;
        color: #e0e0e0;
        padding: 12px;
        user-select: none;
      }
      h2 {
        text-align: center;
        color: #00d4ff;
        font-size: 16px;
        margin-bottom: 10px;
        letter-spacing: 1px;
      }
      .nav-row {
        display: flex;
        gap: 8px;
        margin-bottom: 10px;
      }
      .nav-btn {
        flex: 1;
        padding: 10px;
        border: 1px solid #00d4ff;
        background: #16213e;
        color: #00d4ff;
        font-size: 14px;
        font-weight: bold;
        cursor: pointer;
        border-radius: 4px;
        transition: background 0.2s;
      }
      .nav-btn:hover { background: #0f3460; }
      .nav-btn:active { background: #00d4ff; color: #1a1a2e; }
      .speed-row {
        display: flex;
        align-items: center;
        gap: 8px;
        margin-bottom: 12px;
        font-size: 12px;
        color: #888;
      }
      .speed-row input {
        flex: 1;
        accent-color: #00d4ff;
      }
      .speed-label {
        min-width: 30px;
        text-align: right;
        color: #00d4ff;
      }
      .scene-list {
        list-style: none;
        max-height: 340px;
        overflow-y: auto;
      }
      .scene-list li {
        padding: 9px 12px;
        margin-bottom: 4px;
        background: #16213e;
        border: 1px solid #2a2a4a;
        border-radius: 4px;
        cursor: pointer;
        font-size: 13px;
        transition: background 0.15s, border-color 0.15s;
        white-space: nowrap;
        overflow: hidden;
        text-overflow: ellipsis;
      }
      .scene-list li:hover {
        background: #0f3460;
        border-color: #00d4ff;
      }
      .scene-list li.active {
        background: #00d4ff;
        color: #1a1a2e;
        font-weight: bold;
        border-color: #00d4ff;
      }
      .scene-list::-webkit-scrollbar { width: 6px; }
      .scene-list::-webkit-scrollbar-track { background: #1a1a2e; }
      .scene-list::-webkit-scrollbar-thumb { background: #0f3460; border-radius: 3px; }
      .no-scenes {
        text-align: center;
        color: #666;
        padding: 40px 10px;
        font-style: italic;
      }
      .counter {
        text-align: center;
        font-size: 11px;
        color: #555;
        margin-bottom: 8px;
      }
    </style>
    </head>
    <body>
      <h2>SCENE NAVIGATOR</h2>
      <div class="counter" id="counter"></div>
      <div class="nav-row">
        <button class="nav-btn" onclick="doAction('prev')">&laquo; PREV</button>
        <button class="nav-btn" onclick="doAction('next')">NEXT &raquo;</button>
      </div>
      <div class="speed-row">
        <span>Speed:</span>
        <input type="range" id="speed" min="0" max="40" value="20"
               oninput="updateSpeed(this.value)">
        <span class="speed-label" id="speedVal">2.0s</span>
      </div>
      <ul class="scene-list" id="sceneList"></ul>

      <script>
        function doAction(cmd) {
          window.location = 'skp:action@' + cmd;
        }
        function goToScene(index) {
          window.location = 'skp:goto@' + index;
        }
        function updateSpeed(val) {
          var sec = (val / 10).toFixed(1);
          document.getElementById('speedVal').textContent = sec + 's';
          window.location = 'skp:speed@' + sec;
        }

        // Called from Ruby to refresh the scene list
        function setScenes(names, activeIndex, total) {
          var list = document.getElementById('sceneList');
          var counter = document.getElementById('counter');

          if (total === 0) {
            list.innerHTML = '<li class="no-scenes">No scenes defined.<br>Add scenes in SketchUp first.</li>';
            counter.textContent = '';
            return;
          }
          counter.textContent = 'Scene ' + (activeIndex + 1) + ' of ' + total;

          var html = '';
          for (var i = 0; i < names.length; i++) {
            var cls = (i === activeIndex) ? ' class="active"' : '';
            html += '<li' + cls + ' onclick="goToScene(' + i + ')" title="' + names[i] + '">';
            html += (i + 1) + '. ' + names[i] + '</li>';
          }
          list.innerHTML = html;

          // Scroll active item into view
          var activeEl = list.querySelector('.active');
          if (activeEl) activeEl.scrollIntoView({block: 'nearest'});
        }
      </script>
    </body>
    </html>
    HTML

    @dlg.set_html(html)
    @transition_time = 2.0

    # Refresh scene list in the dialog
    refresh = Proc.new {
      model = Sketchup.active_model
      pages = model.pages
      names = pages.map { |p| p.name.gsub("'", "\\'").gsub('"', '&quot;') }
      active_idx = pages.to_a.index(pages.selected_page) || 0
      total = pages.length
      names_js = "['" + names.join("','") + "']"
      names_js = "[]" if total == 0
      @dlg.execute_script("setScenes(#{names_js}, #{active_idx}, #{total})")
    }

    # Navigate to next/previous scene
    @dlg.add_action_callback("action") do |_dlg, param|
      model = Sketchup.active_model
      pages = model.pages
      next if pages.length == 0

      current_idx = pages.to_a.index(pages.selected_page) || 0

      case param
      when "next"
        new_idx = (current_idx + 1) % pages.length
      when "prev"
        new_idx = (current_idx - 1) % pages.length
      end

      target = pages.to_a[new_idx]
      target.transition_time = @transition_time
      pages.selected_page = target

      UI.start_timer(0.1, false) { refresh.call }
    end

    # Jump to specific scene by index
    @dlg.add_action_callback("goto") do |_dlg, param|
      model = Sketchup.active_model
      pages = model.pages
      idx = param.to_i

      if idx >= 0 && idx < pages.length
        target = pages.to_a[idx]
        target.transition_time = @transition_time
        pages.selected_page = target
        UI.start_timer(0.1, false) { refresh.call }
      end
    end

    # Update transition speed
    @dlg.add_action_callback("speed") do |_dlg, param|
      @transition_time = param.to_f
    end

    @dlg.show

    # Refresh list after dialog opens
    UI.start_timer(0.5, false) { refresh.call }
  end
end

# Launch it
SceneNavigator.show
