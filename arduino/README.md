# ESP32 WebSocket Audio Client

This firmware turns your ESP32-S3 into the Magenta Realtime ESP32 audio client. The ESP32 creates an open WiFi access point named `ELATO`; join that network from your Mac, keep the macOS app running, and the device connects to the app over websocket.

## Pin Configuration

<!-- ### For Seeed Studio XIAO ESP32S3 -->

| **Component**              | **Seeed Studio XIAO ESP32S3** | **General ESP32 Dev Board** |
| -------------------------- | ----------------------------- | --------------------------- |
| **I2S Input (Microphone)** |                               |                             |
| SD                         | D9                            | GPIO 13                     |
| WS                         | D7                            | GPIO 5                      |
| SCK                        | GD8                           | GPIO 18                     |
| **I2S Output (Speaker)**   |                               |                             |
| WS                         | D0                            | GPIO 32                     |
| BCK                        | D1                            | GPIO 33                     |
| DATA                       | D2                            | GPIO 25                     |
| SD (shutdown)              | D3                            | N/A                         |
| **Others**                 |                               |                             |
| LED                        | D4                            | GPIO 2                      |
| Button                     | D5                            | GPIO 26                     |

<!-- 
          I2S Input (Microphone)

          -   SD: D9
          -   WS: D7
          -   SCK: GD8

          I2S Output (Speaker with amp MAX98357A)

          -   WS: D0
          -   BCK: D1
          -   DATA: D2
          -   SD: D3 (shutdown)

          Other

          -   LED: D4
          -   Button: D5

### For a general ESP32 dev board

          I2S Input (Microphone)

          -   SD: GPIO 13
          -   WS: GPIO 5
          -   SCK: GPIO 18

          I2S Output (Speaker)

          -   WS: GPIO 32
          -   BCK: GPIO 33
          -   DATA: GPIO 25

          Other

          -   LED: GPIO 2
          -   Button: GPIO 26 -->

## Firmware With PlatformIO

1. Install PlatformIO IDE (Visual Studio Code extension), or install the CLI:

   ```bash
   python3 -m pip install platformio
   ```

2. Build the firmware from this folder:

   ```bash
   pio run
   ```

3. Upload and monitor:

   ```bash
   pio run -t upload -t monitor
   ```

4. Connect the Mac to the ESP32:
   - Power on the ESP32.
   - Open the WiFi menu on your Mac and join `ELATO`.
   - No DNS, captive portal, WiFi password, or saved WiFi credentials are used.
   - Keep the macOS app open; it remains the Magenta music server.

## Usage

1. Power on the ESP32 device.
2. Join the `ELATO` WiFi network from your Mac.
3. The ESP32 websocket client reconnects until it reaches the macOS app server.
4. The LED indicates the current status:

    - Off: Not connected
    - Solid On: Connected and listening on microphone
    - Pulsing: Streaming audio output (receiving from server)

5. Speak into the microphone to send audio to the server.
6. The device will play audio received from the server through the speaker.

<!-- ## Features -->

<!-- -   Real-time audio streaming using WebSocket
-   Full-duplex I2S audio input (microphone) and I2S audio output (speaker)
-   WiFi connectivity
-   LED status indicator -->
<!-- -   Button interrupt for connection management -->

<!-- ## Hardware Requirements

-   ESP32 development board
-   INMP441 MEMS microphone (I2S input)
-   MAX98357A amplifier (I2S output)
-   LED (for status indication)
-   Push button (for connection control)
-   USB Type-C or Micro USB power cable -->


## Functions

-   `micTask`: Handles audio input from the microphone
-   `buttonTask`: Manages button presses for connection control
-   `ledControlTask`: Controls the LED status indicator
-   `handleTextMessage`: Processes text messages from the server
-   `handleBinaryAudio`: Processes binary audio data from the server

## Customization

You can modify the following parameters in the code:

<!-- -   Audio sample rate (`SAMPLE_RATE`) -->
-   Buffer sizes (`bufferCnt`, `bufferLen`)
<!-- -   LED brightness levels (`MIN_BRIGHTNESS`, `MAX_BRIGHTNESS`) -->
-   Debounce time for the button (`DEBOUNCE_TIME`)

## Troubleshooting

-   If you experience connection issues, make sure the Mac is connected to `ELATO` and the macOS app is open.
-   Ensure all required libraries are installed and up to date.
-   Verify that the pin configuration matches your hardware setup.

## Contributing

Feel free to submit issues or pull requests to improve this firmware.
