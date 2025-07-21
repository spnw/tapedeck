local util = require "src/util"

require "src/Recorder"
require "src/Monitor"

class "TapeDeck"

local function parse_param_string(s)
  local params = {}
  local channels = {}

  for i = 1, s:len() do
    local char = s:sub(i, i)
    if char == "L" then
      channels.left = true
    elseif char == "R" then
      channels.right = true
    elseif char == "s" then
      params.sync_enabled = true
    elseif char == "u" then
      params.sync_enabled = false
    end
  end

  if channels.left and channels.right then
    params.channel_mode = "L+R"
  elseif channels.left then
    params.channel_mode = "L"
  elseif channels.right then
    params.channel_mode = "R"
  end

  return params
end

local function get_recording_params(song, track, child_params)
  if not track then
    return util.merge_tables(Recorder.default_recording_params, child_params)
  end

  local _, s = util.split_name_and_params(track.name)
  local params = parse_param_string(s)

  local parent
  if track.type == renoise.Track.TRACK_TYPE_MASTER then
    parent = nil
  else
    parent = track.group_parent or util.get_master_track(song)
  end
  return get_recording_params(song, parent, util.merge_tables(params, child_params))
end

function TapeDeck:__init()
  self:add_song_release_notifier()
  self.is_initialized = true
end

function TapeDeck:reset_context()
  local song = renoise.song()
  local track = song.selected_track
  self.context = {
    tapedeck = self,
    song = song,
    track = song.selected_track,
    recording_params = get_recording_params(song, track, {})
  }
end

function TapeDeck:ensure_context()
  if not self.context then
    self:reset_context()
  end
  return self.context
end

function TapeDeck:delete_recorder()
  self.recorder = nil
end

function TapeDeck:maybe_delete_monitor()
  if self.monitor and not self.monitor.was_created_manually then
    self.monitor = self.monitor:cleanup()
  end
end

function TapeDeck:record()
  if self.recorder then
    self.recorder:stop_recording()
    return
  end

  self:reset_context()

  local err, manual
  if self.monitor then
    -- Was the monitor created manually, and does it exist on the same
    -- track we're trying to record on?
    manual = (self.monitor.was_created_manually and rawequal(self.monitor.context.track, self.context.track))
    self.monitor:cleanup()
  end
  self.monitor, err = util.ensure_init(Monitor(self.context, manual))
  if not self.monitor then return err end

  self.recorder, err = util.ensure_init(Recorder(self.context))
  if not self.recorder then
    if not self.monitor.was_created_manually then
      self.monitor = self.monitor:cleanup()
    end
    return err
  end
end

function TapeDeck:add_song_release_notifier()
  local o = renoise.tool().app_release_document_observable
  self.song_release_notifier = function()
    self.monitor = nil
    if self.recorder then
      self.recorder = self.recorder:terminate()
    end
    self.context = nil
  end

  o:add_notifier(self.song_release_notifier)
end

function TapeDeck:toggle_monitor()
  if self.recorder then
    return "TapeDeck: Cannot toggle monitor while recording"
  end

  self:reset_context()
  if self.monitor then
    local same_track = rawequal(self.monitor.context.track, self.context.track)
    self.monitor = self.monitor:cleanup()
    if same_track then return end
  end

  self:reset_context()

  local err
  self.monitor, err = util.ensure_init(Monitor(self.context, true))
  if not self.monitor then return err end
end
