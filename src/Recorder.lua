local util = require "src/util"

require "src/TimerManager"

local renoise_config_model = {
  AudioIO = {
    BufferLengths = { BufferLength = 0 },
    NumberOfBuffers = { NumberOfBuffer = 0 },
    SampleRates = { SampleRate = 0 },
  },
  PlayerPrefs = {
    RecordExtraInputLatency = 0
  }
}

local function parse_renoise_config()
  local version = renoise.RENOISE_VERSION:match("^%d+%.%d+%.%d+")
  local config_path

  if os.platform() == "MACINTOSH" then
    local home = os.getenv("HOME")
    config_path = home and ("%s/Library/Preferences/Renoise/V%s/Config.xml"):format(home, version)
  elseif os.platform() == "LINUX" then
    local home = os.getenv("HOME")
    config_path = home and ("%s/.config/Renoise/V%s/Config.xml"):format(home, version)
  elseif os.platform() == "WINDOWS" then
    local home = os.getenv("USERPROFILE")
    config_path = home and ("%s\\AppData\\Roaming\\Renoise\\V%s\\Config.xml"):format(home, version)
  end

  if not config_path then return end

  local doc = renoise.Document.create("RenoisePrefs")(renoise_config_model)
  if not doc:load_from(config_path) then return nil end
  return doc
end

local function get_latency_ms()
  local conf = parse_renoise_config()
  if not conf then return end
  local buffer_length = conf:property("AudioIO"):property("BufferLengths"):property("BufferLength")
  local buffer_count = conf:property("AudioIO"):property("NumberOfBuffers"):property("NumberOfBuffer")
  local extra_latency = conf:property("PlayerPrefs"):property("RecordExtraInputLatency")
  return ((buffer_length * buffer_count * 2) + extra_latency)
end

local function get_latency_samples()
  local conf = parse_renoise_config()
  if not conf then return end
  local buffer_length = conf:property("AudioIO"):property("BufferLengths"):property("BufferLength")
  local buffer_count = conf:property("AudioIO"):property("NumberOfBuffers"):property("NumberOfBuffer")
  local sample_rate = conf:property("AudioIO"):property("SampleRates"):property("SampleRate")
  local extra_latency = conf:property("PlayerPrefs"):property("RecordExtraInputLatency")
  return util.round(((buffer_length * buffer_count * 2) + extra_latency) / 1000 * sample_rate)
end

class "Recorder"

Recorder.default_recording_params = {
  channel = 0,
  channel_mode = "L+R",
  latency_mode = "Live Recording Mode",
  sync_enabled = false,
  monitor_enabled = true,
}

Recorder.placeholder_name = "[TapeDeck is recording]"

function Recorder:__init(context)
  self.context = context
  self.column_mute_state = {}
  self.tm = TimerManager()

  if self.context.song.transport.sample_recording then
    self.error = "TapeDeck: Failed to record (recorder is already active)"
    return
  end

  self.name = util.split_name_and_params(self.context.track.name)
  if not self:add_instrument() then return end
  self:add_instrument_notifier()

  self:mute_columns()
  self:start_recording()

  self.is_initialized = true
end

function Recorder:add_instrument()
  self.instrument, self.instrument_index, self.did_create_instrument = util.find_or_create_empty_instrument(self.context
    .song)
  if not self.instrument then
    self.error = "TapeDeck: Failed to record (too many instruments)"
    return false
  end
  self.context.song.selected_instrument_index = self.instrument_index
  self.instrument.name = Recorder.placeholder_name
  return true
end

function Recorder:delete_or_clear_instrument()
  if (self.did_create_instrument) then
    util.delete_instrument(self.context.song, self.instrument)
  else
    self.instrument:clear()
  end
end

function Recorder:add_instrument_notifier()
  self.selection_notifier = function()
    -- HACK: Setting the index in its own notifier is not particularly
    -- nice.
    self.context.song.selected_instrument_index = self.instrument_index
  end
  self.context.song.selected_instrument_index_observable:add_notifier(self.selection_notifier)
end

function Recorder:remove_instrument_notifier()
  local o = self.context.song.selected_instrument_index_observable
  if o:has_notifier(self.selection_notifier) then
    o:remove_notifier(self.selection_notifier)
  end
end

function Recorder:mute_columns()
  for i = 1, self.context.track.max_note_columns do
    self.column_mute_state[i] = self.context.track:column_is_muted(i)
    self.context.track:set_column_is_muted(i, true)
  end
end

function Recorder:unmute_columns()
  for i, s in ipairs(self.column_mute_state) do
    self.context.track:set_column_is_muted(i, s)
  end
end

function Recorder:start_watchdog()
  local tm = self.tm
  local ctx = self.context
  local delay = math.max(100, (get_latency_ms() or 0))

  tm:schedule(delay,
    function()
      if ctx.song.transport.sample_recording then
        -- If we're recording, keep waiting.
        return true
      end

      -- Recording has finished.
      if ctx.recording_params.sync_enabled then
        ctx.song.transport:stop()
      end

      tm:schedule(delay,
        function()
          if self.instrument.name:match("^Recorded Sample %d+$") then
            -- The instrument's name has changed.
            self:cleanup(self:fixup_instrument())
          else
            self:cleanup(false)
          end
        end)
    end)
end

function Recorder:start_recording()
  self.context.song.transport.sample_recording_sync_enabled = self.context.recording_params.sync_enabled
  self.old_precount_setting = self.context.song.transport.metronome_precount_enabled
  if self.context.recording_params.sync_enabled then
    self.context.song.transport.metronome_precount_enabled = false
  end
  util.show_recorder()
  self.context.song.transport:start_sample_recording()
  if self.context.recording_params.sync_enabled then
    self.context.song.transport:start(renoise.Transport.PLAYMODE_RESTART_PATTERN)
  end
  self:start_watchdog()
end

function Recorder:stop_recording()
  self.context.song.transport:stop_sample_recording()
end

function Recorder:process_sample(channel, offset)
  -- Stereo, uncompensated audio doesn't need processing.
  if not channel and (offset == 0) then return true end

  local ins = self.instrument
  if not ins then return end
  local s1 = ins.samples[1]
  local b1 = s1.sample_buffer
  local s2 = ins:insert_sample_at(2)
  local b2 = s2.sample_buffer
  local length = (b1.number_of_frames - offset)
  if length < 1 then
    -- Recording is shorter than offset
    return false
  end
  b2:create_sample_data(b1.sample_rate, b1.bit_depth, channel and 1 or 2, length)
  b2:prepare_sample_data_changes(true)
  if channel then
    -- Mono
    for frame = 1, b2.number_of_frames do
      b2:set_sample_data(1, frame, b1:sample_data(channel, (frame + offset)))
    end
  else
    -- Stereo
    for frame = 1, b2.number_of_frames do
      b2:set_sample_data(1, frame, b1:sample_data(1, (frame + offset)))
      b2:set_sample_data(2, frame, b1:sample_data(2, (frame + offset)))
    end
  end

  b2:finalize_sample_data_changes()
  self.instrument:delete_sample_at(1)
  return true
end

function Recorder:fixup_instrument()
  local name = ("%s [%s]"):format(self.name, os.date("%Y-%m-%d %H:%M:%S"))
  self.instrument.name = name

  local offset
  if not self.context.recording_params.monitor_enabled then
    offset = get_latency_samples()
    if not offset then
      renoise.app():show_warning("TapeDeck failed to get latency info. Recording will not be latency-compensated.")
      offset = 0
    end
  else
    offset = 0
  end

  local result
  if self.context.recording_params.channel_mode == "L" then
    result = self:process_sample(1, offset)
  elseif self.context.recording_params.channel_mode == "R" then
    result = self:process_sample(2, offset)
  else
    result = self:process_sample(nil, offset)
  end
  if not result then return false end

  local sample = self.instrument.samples[1]
  sample.name = name
  sample.autoseek = true
  sample.autofade = true

  return true
end

function Recorder:cleanup(keep_instrument)
  self:remove_instrument_notifier()

  if not keep_instrument then
    self:delete_or_clear_instrument()
  end

  self.context.song.transport.metronome_precount_enabled = self.old_precount_setting
  self.tm:cancel_all()
  util.hide_recorder()
  self:unmute_columns()

  self.context.tapedeck:delete_recorder()
  self.context.tapedeck:maybe_delete_monitor()
end

-- Make a hasty exit (e.g. when new song invalidates our context)
function Recorder:terminate()
  self.tm:cancel_all()
end
