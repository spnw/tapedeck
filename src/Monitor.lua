local util = require "src/util"

class "Monitor"

local TEMPLATE_LINE_IN_DEVICE = [[<?xml version="1.0" encoding="UTF-8"?>
<FilterDevicePreset doc_version="14">
  <DeviceSlot type="LineInDevice">
    <IsMaximized>true</IsMaximized>
    <InputChannel>%d</InputChannel>
    <InputChannelMode>%s</InputChannelMode>
    <InputLatencyMode>%s</InputLatencyMode>
    <Panning>
      <Value>0.5</Value>
    </Panning>
    <Volume>
      <Value>1.0</Value>
    </Volume>
  </DeviceSlot>
</FilterDevicePreset>]]

function Monitor:__init(context, created_manually)
  self.context = context
  self:add_line_in_device(context.recording_params)
  self.was_created_manually = created_manually
  self.is_initialized = true
end

function Monitor:cleanup()
  self:delete_line_in_device()
end

function Monitor:add_line_in_device(params)
  self.line_in_device = self.context.track:insert_device_at("Audio/Effects/Native/#Line Input", 2)
  self.line_in_device.display_name = ("TapeDeck In [%s]"):format(params.channel_mode)
  self.line_in_device.active_preset_data = TEMPLATE_LINE_IN_DEVICE:format(
    params.channel,
    params.channel_mode,
    params.latency_mode)
end

function Monitor:delete_line_in_device()
  util.delete_device(self.context.track, self.line_in_device)
end
