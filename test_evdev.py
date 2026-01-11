#!/usr/bin/env python3
"""Test if evdev can detect keyboard events"""

from evdev import InputDevice, categorize, ecodes, list_devices

def find_keyboard_device():
    """Find the keyboard input device"""
    devices = [InputDevice(path) for path in list_devices()]

    print("Available input devices:")
    for i, device in enumerate(devices):
        print(f"  {i}: {device.name} - {device.path}")
        if ecodes.EV_KEY in device.capabilities():
            print(f"      Has keyboard capabilities")

    print()

    # Filter for real keyboards (exclude virtual devices and mice)
    keyboards = []
    for device in devices:
        # Skip virtual devices
        if 'virtual' in device.name.lower():
            continue
        # Skip mice, touchpads, pens, etc
        if any(x in device.name.lower() for x in ['mouse', 'touchpad', 'trackpoint', 'pen', 'finger']):
            continue
        # Must have keyboard capabilities
        if ecodes.EV_KEY in device.capabilities():
            keys = device.capabilities()[ecodes.EV_KEY]
            # Must have space and ctrl keys
            if ecodes.KEY_SPACE in keys and ecodes.KEY_LEFTCTRL in keys:
                keyboards.append(device)

    # Prefer actual keyboard names
    for device in keyboards:
        if 'keyboard' in device.name.lower():
            return device

    # Fall back to first one found
    if keyboards:
        return keyboards[0]

    return None


print("Testing evdev keyboard detection...")
print()

device = find_keyboard_device()

if not device:
    print("ERROR: No keyboard device found!")
    print("Make sure you're in the 'input' group:")
    print("  sudo usermod -aG input $USER")
    print("Then log out and log back in.")
    exit(1)

print(f"Using keyboard: {device.name}")
print(f"Device path: {device.path}")
print()
print("Press some keys (including Ctrl+Alt+Space)...")
print("Press Ctrl+C to quit")
print()

try:
    for event in device.read_loop():
        if event.type == ecodes.EV_KEY:
            key_event = categorize(event)

            # Get key name
            try:
                key_name = ecodes.KEY[event.code]
            except:
                key_name = f"Unknown({event.code})"

            # Key pressed
            if key_event.keystate == key_event.key_down:
                print(f"Key pressed:  {key_name}")
            # Key released
            elif key_event.keystate == key_event.key_up:
                print(f"Key released: {key_name}")

except PermissionError:
    print()
    print("ERROR: Permission denied!")
    print("Make sure you're in the 'input' group:")
    print("  sudo usermod -aG input $USER")
    print("Then log out and log back in.")
except KeyboardInterrupt:
    print()
    print("Test stopped.")
