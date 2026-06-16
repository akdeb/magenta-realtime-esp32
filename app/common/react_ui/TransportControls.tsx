/**
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import IconButton from '@mui/material/IconButton';
import Tooltip from '@mui/material/Tooltip';
import { VolumeControl } from './VolumeControl';
import { Replay } from '@mui/icons-material';
import { Brain, Laptop, LoaderCircle, Speaker, VolumeX } from 'lucide-react';

type VoiceStatus = 'idle' | 'listening' | 'processing' | 'thinking' | 'done' | 'error';

interface TransportControlsProps {
  isPlaying: boolean;
  onTogglePlay: () => void;
  volume: number;
  onVolumeChange: (v: number) => void;
  onReset: () => void;
  onResetDown?: () => void;
  onResetUp?: () => void;
  volumeSliderPosition?: 'top' | 'bottom';
  model?: string;
  resetTooltip?: string;
  showPlay?: boolean;
  showReset?: boolean;
  showVolume?: boolean;
  isDawPlaying?: boolean;
  showSpeaker?: boolean;
  speakerStreaming?: boolean;
  onToggleSpeaker?: () => void;
  voiceStatus?: VoiceStatus;
  speakerButtonVariant?: 'speaker' | 'laptop';
}

export function TransportControls({
  isPlaying,
  onTogglePlay,
  volume,
  onVolumeChange,
  onReset,
  onResetDown,
  onResetUp,
  volumeSliderPosition = 'top',
  model,
  resetTooltip = 'Reset model state',
  showPlay = true,
  showReset = true,
  showVolume = true,
  isDawPlaying = false,
  showSpeaker = false,
  speakerStreaming = false,
  onToggleSpeaker,
  voiceStatus = 'idle',
  speakerButtonVariant = 'speaker',
}: TransportControlsProps) {
  const noModel = !model || model === 'No model loaded';
  const isVoiceBusy = voiceStatus === 'processing' || voiceStatus === 'thinking';
  const speakerTooltip = speakerButtonVariant === 'laptop'
    ? speakerStreaming ? 'Disable laptop output' : 'Enable laptop output'
    : isVoiceBusy
    ? 'Thinking about your ESP32 voice command'
    : speakerStreaming ? 'Stop ESP32 speaker stream' : 'Start ESP32 speaker stream';
  const secondaryActive = speakerStreaming;
  const playButton = (
    <button
      onClick={noModel || isVoiceBusy ? undefined : onTogglePlay}
      disabled={noModel || isVoiceBusy}
      style={{
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        width: '56px',
        height: '56px',
        borderRadius: '50%',
        border: 'none',
        background: isVoiceBusy ? 'var(--color-control-bg-active, rgba(255,122,0,0.14))' : isDawPlaying ? '#FF7A00' : 'var(--color-play-bg, #FFF)',
        color: isDawPlaying ? '#000' : 'var(--color-play-fg, #000)',
        padding: 0,
        flexShrink: 0,
        opacity: noModel ? 0.4 : 1,
        animation: isDawPlaying ? 'magenta-pulse 2s infinite ease-in-out' : 'none',
      }}
    >
      {voiceStatus === 'thinking' ? (
        <Brain size={27} />
      ) : voiceStatus === 'processing' || voiceStatus === 'listening' ? (
        <LoaderCircle size={27} className="voice-status-spin" />
      ) : (
        <span className="material-icons" style={{ fontSize: '28px' }}>
          {isDawPlaying ? 'cable' : (isPlaying ? 'pause' : 'play_arrow')}
        </span>
      )}
    </button>
  );

  return (
    <div style={{
      display: 'flex',
      alignItems: 'center',
      gap: '8px',
    }}>
      {showReset && (
        <Tooltip title={resetTooltip}>
          <IconButton
            onClick={onReset}
            onMouseDown={onResetDown}
            onMouseUp={onResetUp}
            onMouseLeave={onResetUp}
            sx={{
              width: 40,
              height: 40,
            }}
          >
            <Replay sx={{ fontSize: 20 }} />
          </IconButton>
        </Tooltip>
      )}

      {/* Play/Pause — large circle */}
      {showPlay && (noModel ? (
        <Tooltip title="No model selected" placement="top">
          <span>{playButton}</span>
        </Tooltip>
      ) : isDawPlaying ? (
        <Tooltip title="Linked to DAW" placement="top">
          <span>{playButton}</span>
        </Tooltip>
      ) : (
        playButton
      ))}

      {showSpeaker && (
        <Tooltip title={speakerTooltip} placement="top">
          <span>
            <IconButton
              onClick={onToggleSpeaker}
              disabled={!onToggleSpeaker || (speakerButtonVariant === 'speaker' && isVoiceBusy)}
              sx={{
                width: 40,
                height: 40,
                color: secondaryActive ? 'var(--color-accent, #FF7A00)' : 'var(--color-fg)',
                background: secondaryActive ? 'var(--color-control-bg-active, rgba(255,122,0,0.14))' : 'transparent',
                opacity: speakerButtonVariant === 'laptop' && !secondaryActive ? 0.58 : 1,
              }}
            >
              {speakerButtonVariant === 'laptop'
                ? <Laptop size={20} />
                : voiceStatus === 'thinking'
                  ? <Brain size={20} />
                  : voiceStatus === 'processing'
                    ? <LoaderCircle size={20} className="voice-status-spin" />
                    : speakerStreaming ? <Speaker size={20} /> : <VolumeX size={20} />}
            </IconButton>
          </span>
        </Tooltip>
      )}

      {/* Volume */}
      {showVolume && (
        <VolumeControl
          volume={volume}
          onVolumeChange={onVolumeChange}
          sliderPosition={volumeSliderPosition}
        />
      )}
    </div>
  );
}
