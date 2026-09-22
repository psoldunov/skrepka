import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

import {isWithinEncodedLimit} from './limits.js';

const BUS_NAME = 'dev.soldunov.Skrepka';
const OBJECT_PATH = '/dev/soldunov/Skrepka';
const INTERFACE = 'dev.soldunov.Skrepka1';
const DOCUMENT_VERSION = 6;
const REPLY_TYPE = new GLib.VariantType('(s)');

export function submit(representations, sourceApplication, isConcealed) {
    if (!isWithinEncodedLimit(representations)) {
        console.warn('Skrepka clipboard submission exceeded the encoded size limit');
        return;
    }

    const request = JSON.stringify({
        version: DOCUMENT_VERSION,
        representations,
        sourceApplication,
        isConcealed,
    });

    Gio.DBus.session.call(
        BUS_NAME,
        OBJECT_PATH,
        INTERFACE,
        'Submit',
        new GLib.Variant('(s)', [request]),
        REPLY_TYPE,
        Gio.DBusCallFlags.NONE,
        15_000,
        null,
        (connection, result) => {
            try {
                connection.call_finish(result);
            } catch (error) {
                console.warn(`Skrepka clipboard submission failed: ${error.message}`);
            }
        }
    );
}

export function setShellExtensionActive(active) {
    Gio.DBus.session.call(
        BUS_NAME,
        OBJECT_PATH,
        INTERFACE,
        'SetShellExtensionActive',
        new GLib.Variant('(b)', [active]),
        REPLY_TYPE,
        Gio.DBusCallFlags.NONE,
        15_000,
        null,
        (connection, result) => {
            try {
                connection.call_finish(result);
            } catch (error) {
                console.warn(`Skrepka extension status update failed: ${error.message}`);
            }
        }
    );
}
