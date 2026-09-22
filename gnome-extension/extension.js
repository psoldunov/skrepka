import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

import {setShellExtensionActive, submit} from './dbus.js';
import {
    MAX_CAPTURE_BYTES,
    MAX_ENCODED_CAPTURE_BYTES,
    base64EncodedSize,
} from './limits.js';

const CLIPBOARD = Meta.SelectionType.SELECTION_CLIPBOARD;
const DEBOUNCE_MILLISECONDS = 150;
const HEARTBEAT_MILLISECONDS = 15_000;
const SENSITIVE_TARGET = 'x-kde-passwordManagerHint';
const SENSITIVE_VALUE = 'secret';
const SENSITIVE_LIMIT = 64;

const REPRESENTATIONS = [
    {
        canonical: 'text/plain;charset=utf-8',
        targets: [
            'text/plain;charset=utf-8',
            'UTF8_STRING',
            'text/plain',
            'STRING',
        ],
    },
    {canonical: 'text/html', targets: ['text/html']},
    {canonical: 'image/png', targets: ['image/png']},
    {canonical: 'image/tiff', targets: ['image/tiff']},
    {canonical: 'image/jpeg', targets: ['image/jpeg']},
    {canonical: 'application/pdf', targets: ['application/pdf']},
    {canonical: 'text/rtf', targets: ['text/rtf']},
    {
        canonical: 'text/uri-list',
        targets: ['text/uri-list', 'x-special/gnome-copied-files'],
    },
];

function focusedApplication() {
    const window = global.display.get_focus_window();
    return window?.get_gtk_application_id?.()
        ?? window?.get_sandboxed_app_id?.()
        ?? window?.get_wm_class?.()
        ?? null;
}

function utf8Bytes(bytes, target) {
    if (target !== 'STRING')
        return bytes;

    const text = new TextDecoder('iso-8859-1').decode(bytes);
    return new TextEncoder().encode(text);
}

function readTarget(selection, target, limit, cancellable) {
    return new Promise((resolve, reject) => {
        const output = Gio.MemoryOutputStream.new_resizable();
        selection.transfer_async(
            CLIPBOARD,
            target,
            limit,
            output,
            cancellable,
            (source, result) => {
                try {
                    source.transfer_finish(result);
                    output.close(null);
                    resolve(output.steal_as_bytes().toArray());
                } catch (error) {
                    reject(error);
                }
            }
        );
    });
}

export default class SkrepkaExtension extends Extension {
    enable() {
        this._generation = 0;
        this._timeout = 0;
        this._heartbeat = 0;
        this._transfer = null;
        this._selection = null;
        this._ownerChanged = 0;
        if (!global.backend.get_context().get_wayland_compositor())
            return;

        this._selection = global.display.get_selection();
        this._ownerChanged = this._selection.connect(
            'owner-changed',
            this._onOwnerChanged.bind(this)
        );
        setShellExtensionActive(true);
        this._heartbeat = GLib.timeout_add(
            GLib.PRIORITY_DEFAULT,
            HEARTBEAT_MILLISECONDS,
            () => {
                setShellExtensionActive(true);
                return GLib.SOURCE_CONTINUE;
            }
        );
    }

    disable() {
        this._generation += 1;
        if (this._timeout) {
            GLib.source_remove(this._timeout);
            this._timeout = 0;
        }
        if (this._heartbeat) {
            GLib.source_remove(this._heartbeat);
            this._heartbeat = 0;
            setShellExtensionActive(false);
        }
        this._transfer?.cancel();
        this._transfer = null;
        if (this._ownerChanged) {
            this._selection.disconnect(this._ownerChanged);
            this._ownerChanged = 0;
        }
        this._selection = null;
    }

    _onOwnerChanged(_selection, selectionType) {
        if (selectionType !== CLIPBOARD)
            return;

        const generation = ++this._generation;
        const sourceApplication = focusedApplication();
        if (this._timeout)
            GLib.source_remove(this._timeout);
        this._transfer?.cancel();
        this._transfer = null;

        this._timeout = GLib.timeout_add(
            GLib.PRIORITY_DEFAULT,
            DEBOUNCE_MILLISECONDS,
            () => {
                this._timeout = 0;
                this._capture(generation, sourceApplication);
                return GLib.SOURCE_REMOVE;
            }
        );
    }

    async _capture(generation, sourceApplication) {
        const selection = this._selection;
        if (!selection || generation !== this._generation)
            return;

        const offered = new Set(selection.get_mimetypes(CLIPBOARD) ?? []);
        const cancellable = new Gio.Cancellable();
        this._transfer = cancellable;

        try {
            const isConcealed = await this._isConcealed(
                selection,
                offered,
                cancellable
            );
            if (isConcealed)
                return;

            const representations = await this._readRepresentations(
                selection,
                offered,
                cancellable,
                generation
            );
            if (generation !== this._generation || Object.keys(representations).length === 0)
                return;
            submit(representations, sourceApplication, false);
        } catch (error) {
            if (generation === this._generation)
                console.warn(`Skrepka could not read the clipboard: ${error.message}`);
        } finally {
            if (this._transfer === cancellable)
                this._transfer = null;
        }
    }

    async _isConcealed(selection, offered, cancellable) {
        if (!offered.has(SENSITIVE_TARGET))
            return false;

        const bytes = await readTarget(
            selection,
            SENSITIVE_TARGET,
            SENSITIVE_LIMIT + 1,
            cancellable
        );
        if (bytes.length > SENSITIVE_LIMIT)
            throw new Error('the clipboard sensitivity marker is too large');
        return new TextDecoder().decode(bytes).trim() === SENSITIVE_VALUE;
    }

    async _readRepresentations(selection, offered, cancellable, generation) {
        const result = {};
        let remaining = MAX_CAPTURE_BYTES;
        let encodedRemaining = MAX_ENCODED_CAPTURE_BYTES;

        for (const representation of REPRESENTATIONS) {
            for (const target of representation.targets) {
                if (!offered.has(target))
                    continue;

                let bytes;
                try {
                    bytes = await readTarget(selection, target, remaining + 1, cancellable);
                } catch (error) {
                    if (generation !== this._generation)
                        throw error;
                    continue;
                }
                if (generation !== this._generation)
                    return {};

                bytes = utf8Bytes(bytes, target);
                if (bytes.length > remaining)
                    throw new Error('the clipboard item is over the 32 MiB limit');
                if (bytes.length === 0)
                    continue;

                const encodedSize = base64EncodedSize(bytes.length);
                if (encodedSize > encodedRemaining)
                    throw new Error('the clipboard item is over the encoded submission limit');
                const encoded = GLib.base64_encode(bytes);
                result[representation.canonical] = encoded;
                remaining -= bytes.length;
                encodedRemaining -= encoded.length;
                break;
            }
        }
        return result;
    }
}
