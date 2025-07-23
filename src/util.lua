-- Miscellanous utility functions for TapeDeck.

local util = {}

function util.round(n)
  return math.floor(n + 0.5)
end

function util.merge_tables(a, b)
  local new = table.copy(a)
  for k, v in pairs(b) do
    new[k] = v
  end
  return new
end

function util.trim_whitespace(s)
  return s:gsub("^%s*", ""):gsub("%s*$", "")
end

function util.ensure_init(object)
  if object.is_initialized then
    return object
  else
    return nil, object.error
  end
end

function util.get_master_track(song)
  for _, track in ipairs(song.tracks) do
    if track.type == renoise.Track.TRACK_TYPE_MASTER then
      return track
    end
  end
end

-- TODO: Guard against deleting the last instrument in a song.
function util.delete_instrument(song, instrument)
  for idx, ins in ipairs(song.instruments) do
    if rawequal(ins, instrument) then
      song:delete_instrument_at(idx)
      return
    end
  end
end

function util.delete_device(track, device)
  for idx, dev in ipairs(track.devices) do
    if rawequal(dev, device) then
      track:delete_device_at(idx)
      return
    end
  end
end

function util.show_recorder()
  renoise.app().window.sample_record_dialog_is_visible = true
end

function util.hide_recorder()
  renoise.app().window.sample_record_dialog_is_visible = false
end

-- This is an attempt at implementing Renoise's heuristic about
-- whether a track is sufficiently "empty" that it's okay to record a
-- sample onto it.
function util.instrument_is_empty(instrument)
  return (instrument.name == ""
    and #instrument.samples == 0
    and #instrument.phrases == 0
    and #instrument.sample_modulation_sets == 1
    and #instrument.sample_modulation_sets[1].devices == 0
    and not instrument.plugin_properties.plugin_loaded)
end

function util.find_or_create_empty_instrument(song)
  -- Find and return first empty instrument in song.
  for idx, ins in ipairs(song.instruments) do
    if util.instrument_is_empty(ins) then
      return ins, idx, false
    end
  end

  -- If no empty instrument was found, and there is still space for
  -- one, create and return one.  Otherwise return nothing.
  local idx = #song.instruments + 1
  if idx > renoise.Song.MAX_NUMBER_OF_INSTRUMENTS then
    return
  end
  return song:insert_instrument_at(idx), idx, true
end

function util.split_name_and_params(name)
  name = util.trim_whitespace(name)
  local match_start, match_end = name:find("%b[]$")
  if match_start then
    return
        util.trim_whitespace(name:sub(1, match_start - 1)),
        util.trim_whitespace(name:sub(match_start + 1, match_end - 1))
  else
    return name, ""
  end
end

return util
