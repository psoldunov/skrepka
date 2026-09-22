export const MAX_CAPTURE_BYTES = 32 * 1024 * 1024;
export const MAX_ENCODED_CAPTURE_BYTES = Math.ceil(MAX_CAPTURE_BYTES / 3) * 4 + 4;

export function base64EncodedSize(byteCount) {
    return Math.ceil(byteCount / 3) * 4;
}

export function isWithinEncodedLimit(representations) {
    let total = 0;
    for (const encoded of Object.values(representations)) {
        total += new TextEncoder().encode(encoded).length;
        if (total > MAX_ENCODED_CAPTURE_BYTES)
            return false;
    }
    return true;
}
