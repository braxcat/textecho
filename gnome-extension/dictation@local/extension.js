import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';

const DBUS_INTERFACE = `
<node>
  <interface name="com.dictation.WindowPositioner">
    <method name="PositionAtMouse">
      <arg type="s" direction="in" name="wm_class"/>
      <arg type="b" direction="out" name="success"/>
    </method>
    <method name="GetMousePosition">
      <arg type="i" direction="out" name="x"/>
      <arg type="i" direction="out" name="y"/>
    </method>
    <method name="StartFollowing">
      <arg type="s" direction="in" name="wm_class"/>
      <arg type="b" direction="out" name="success"/>
    </method>
    <method name="StopFollowing">
      <arg type="b" direction="out" name="success"/>
    </method>
  </interface>
</node>`;

const FOLLOW_INTERVAL_MS = 16;  // ~60 FPS

export default class DictationExtension {
    constructor() {
        this._dbusId = null;
        this._followingWmClass = null;
        this._followTimeoutId = null;
    }

    enable() {
        this._dbusId = Gio.DBus.session.own_name(
            'com.dictation.WindowPositioner',
            Gio.BusNameOwnerFlags.NONE,
            this._onBusAcquired.bind(this),
            null,
            null
        );
        console.log('[Dictation] Extension enabled');
    }

    disable() {
        this._stopFollowing();
        if (this._dbusId) {
            Gio.DBus.session.unown_name(this._dbusId);
            this._dbusId = null;
        }
        console.log('[Dictation] Extension disabled');
    }

    _onBusAcquired(connection, name) {
        const nodeInfo = Gio.DBusNodeInfo.new_for_xml(DBUS_INTERFACE);
        connection.register_object(
            '/com/dictation/WindowPositioner',
            nodeInfo.interfaces[0],
            this._handleMethodCall.bind(this),
            null,
            null
        );
        console.log('[Dictation] D-Bus interface registered');
    }

    _handleMethodCall(connection, sender, objectPath, interfaceName, methodName, parameters, invocation) {
        if (methodName === 'PositionAtMouse') {
            const wmClass = parameters.deep_unpack()[0];
            const success = this._positionWindowAtMouse(wmClass);
            invocation.return_value(new GLib.Variant('(b)', [success]));
        } else if (methodName === 'GetMousePosition') {
            const [x, y] = global.get_pointer();
            invocation.return_value(new GLib.Variant('(ii)', [x, y]));
        } else if (methodName === 'StartFollowing') {
            const wmClass = parameters.deep_unpack()[0];
            const success = this._startFollowing(wmClass);
            invocation.return_value(new GLib.Variant('(b)', [success]));
        } else if (methodName === 'StopFollowing') {
            const success = this._stopFollowing();
            invocation.return_value(new GLib.Variant('(b)', [success]));
        } else {
            invocation.return_error_literal(
                Gio.DBusError,
                Gio.DBusError.UNKNOWN_METHOD,
                `Unknown method ${methodName}`
            );
        }
    }

    _positionWindowAtMouse(wmClass) {
        const [mouseX, mouseY] = global.get_pointer();

        // Find window by wm_class or title
        const windows = global.get_window_actors();
        for (const actor of windows) {
            const metaWindow = actor.get_meta_window();
            if (!metaWindow) continue;

            const windowClass = metaWindow.get_wm_class();
            const windowClassInstance = metaWindow.get_wm_class_instance();
            const windowTitle = metaWindow.get_title();

            // Match wm_class, wm_class_instance, or title (GTK4 on Wayland uses title)
            if (windowClass === wmClass ||
                windowClassInstance === wmClass ||
                windowTitle === wmClass) {
                // Get window dimensions
                const rect = metaWindow.get_frame_rect();

                // Position window centered horizontally, above the cursor
                const newX = mouseX - Math.floor(rect.width / 2);
                const newY = mouseY - rect.height - 20;  // 20px above cursor

                // Move the window
                metaWindow.move_frame(true, newX, newY);

                // Raise it
                metaWindow.activate(global.get_current_time());

                console.log(`[Dictation] Moved "${wmClass}" to (${newX}, ${newY})`);
                return true;
            }
        }

        console.log(`[Dictation] Window "${wmClass}" not found`);
        return false;
    }

    _startFollowing(wmClass) {
        // Stop any existing following
        this._stopFollowing();

        this._followingWmClass = wmClass;

        // Do initial position
        this._positionWindowAtMouse(wmClass);

        // Start the follow loop
        this._followTimeoutId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, FOLLOW_INTERVAL_MS, () => {
            if (this._followingWmClass) {
                this._positionWindowAtMouse(this._followingWmClass);
                return GLib.SOURCE_CONTINUE;
            }
            return GLib.SOURCE_REMOVE;
        });

        console.log(`[Dictation] Started following "${wmClass}"`);
        return true;
    }

    _stopFollowing() {
        if (this._followTimeoutId) {
            GLib.source_remove(this._followTimeoutId);
            this._followTimeoutId = null;
        }
        this._followingWmClass = null;
        console.log('[Dictation] Stopped following');
        return true;
    }
}
