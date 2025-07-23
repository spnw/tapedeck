local util = require "src/util"

class "Recorder"

Recorder.default_recording_params = {
  channel = 0,
  channel_mode = "L+R",
  latency_mode = "Live Recording Mode",
  sync_enabled = false,
}

Recorder.placeholder_name = "[TapeDeck is recording]"

function Recorder:__init(context)
  self.context = context
  self.column_mute_state = {}

  if self.context.song.transport.sample_recording then
    self.error = "TapeDeck: Failed to record (recorder is already active)"
    return
  end

  self.name = util.split_name_and_params(self.context.track.name)
  if not self:add_instrument() then return end
  self:add_instrument_notifier()

  self:mute_columns()
  self.watchdog = Watchdog(self, 100)
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
  self.watchdog:start()
end

function Recorder:stop_recording()
  self.context.song.transport:stop_sample_recording()
end

function Recorder:convert_to_mono(channel)
  local ins = self.instrument
  if not ins then return end
  local s1 = ins.samples[1]
  local b1 = s1.sample_buffer
  local s2 = ins:insert_sample_at(2)
  local b2 = s2.sample_buffer
  b2:create_sample_data(b1.sample_rate, b1.bit_depth, 1, b1.number_of_frames)
  b2:prepare_sample_data_changes(true)
  for frame = 1, b2.number_of_frames do
    b2:set_sample_data(1, frame, b1:sample_data(channel, frame))
  end
  b2:finalize_sample_data_changes()
  self.instrument:delete_sample_at(1)
end

function Recorder:fixup_instrument()
  local name = ("%s [%s]"):format(self.name, os.date("%Y-%m-%d %H:%M:%S"))
  self.instrument.name = name
  if self.context.recording_params.channel_mode == "L" then
    self:convert_to_mono(1)
  elseif self.context.recording_params.channel_mode == "R" then
    self:convert_to_mono(2)
  end
  local sample = self.instrument.samples[1]
  sample.name = name
  sample.autoseek = true
  sample.autofade = true
end

function Recorder:cleanup(keep_instrument)
  self:remove_instrument_notifier()

  if not keep_instrument then
    self:delete_or_clear_instrument()
  end

  self.context.song.transport.metronome_precount_enabled = self.old_precount_setting
  self.watchdog:stop()
  util.hide_recorder()
  self:unmute_columns()

  self.context.tapedeck:delete_recorder()
  self.context.tapedeck:maybe_delete_monitor()
end

-- Make a hasty exit (e.g. when new song invalidates our context)
function Recorder:terminate()
  self.watchdog:stop()
end

function Recorder:wait_for_instrument()
  local max_attempts = 2

  if not self.is_waiting_for_instrument then
    self.is_waiting_for_instrument = true
    self.attempts = 1
  end

  if self.instrument.name:match("^Recorded Sample %d+$") then
    -- The instrument's name has changed.
    self:fixup_instrument()
    self:cleanup(true)
  else
    if self.attempts == max_attempts then
      self:cleanup(false)
    else
      self.attempts = self.attempts + 1
    end
  end
end

class "Watchdog"

function Watchdog:__init(recorder, interval)
  self.interval = interval
  self.fn = function()
    if recorder.is_waiting_for_instrument then
      recorder:wait_for_instrument()
    else
      if recorder.context.song.transport.sample_recording then
        return
      end
      if recorder.context.recording_params.sync_enabled then
        recorder.context.song.transport:stop()
      end
      recorder:wait_for_instrument()
    end
  end
end

function Watchdog:start()
  renoise.tool():add_timer(self.fn, self.interval)
end

function Watchdog:stop()
  if renoise.tool():has_timer(self.fn) then
    renoise.tool():remove_timer(self.fn)
  end
end
