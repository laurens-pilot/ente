import type { EnteFile } from "ente-media/file";
import type {
    FilePublicMagicMetadataData,
    ParsedMetadataDate,
} from "ente-media/file-metadata";
import { FileType } from "ente-media/file-type";
import { createMagicMetadata } from "ente-media/magic-metadata";
import { beforeEach, expect, test, vi } from "vitest";
import {
    repairFileCreationTimes,
    type FileTimeRepairProgress,
} from "../src/services/fix-creation-time";

const { save, download, extractDates } = vi.hoisted(() => ({
    save: vi.fn(),
    download: vi.fn(),
    extractDates: vi.fn(),
}));
vi.mock("ente-new/photos/services/file", () => ({
    updateFilePublicMagicMetadata: save,
}));
vi.mock("ente-gallery/services/download", () => ({
    downloadManager: { fileBlob: download },
}));
vi.mock("ente-gallery/services/exif", () => ({
    extractExifDates: extractDates,
}));
vi.mock("ente-base/log", async (importOriginal) => {
    const actual = await importOriginal<typeof import("ente-base/log")>();
    return { ...actual, default: { ...actual.default, error: vi.fn() } };
});

const timestamp = (value: string) => new Date(value).getTime() * 1000;
const oldTime = timestamp("2026-11-12T00:06:00");
const desiredTime = timestamp("2024-06-29T00:00:00");
const file = (id: number, title: string, creationTime = oldTime) =>
    ({
        id,
        metadata: {
            title,
            fileType: FileType.image,
            creationTime,
            modificationTime: oldTime,
        },
    }) as EnteFile;

beforeEach(() => {
    vi.resetAllMocks();
    save.mockResolvedValue(undefined);
    download.mockResolvedValue(new Blob());
    extractDates.mockResolvedValue({});
});

test("reports actual outcomes for a mixed filename repair batch", async () => {
    save.mockImplementation((f: EnteFile) => {
        if (f.id === 4) return Promise.reject(new Error("save failed"));
        return Promise.resolve();
    });
    const snapshots: FileTimeRepairProgress[] = [];
    const result = await repairFileCreationTimes(
        [
            file(1, "IMG - 3613 2024-06-29.heic"),
            file(2, "2024-06-29.heic", desiredTime),
            file(3, "IMG - 3615.heic"),
            file(4, "2024-06-30.heic"),
        ],
        "file-name",
        undefined,
        (progress) => snapshots.push(progress),
    );
    expect(result).toEqual({
        total: 4,
        processed: 4,
        updated: 1,
        unchanged: 1,
        skipped: 1,
        failed: 1,
    });
    expect(save).toHaveBeenCalledTimes(2);
    expect(save.mock.calls[0]?.[1]).toEqual({
        editedTime: desiredTime,
        dateTime: undefined,
        offsetTime: undefined,
    });
    expect(snapshots.map((p) => p.processed)).toEqual([0, 1, 2, 3, 4]);
    for (const p of snapshots)
        expect(p.updated + p.unchanged + p.skipped + p.failed).toBe(
            p.processed,
        );
    expect(download).not.toHaveBeenCalled();
});

test("a batch without recognizable dates has no successful updates", async () => {
    const result = await repairFileCreationTimes(
        [file(1, "IMG_3613.heic")],
        "file-name",
        undefined,
        vi.fn(),
    );
    expect(result).toEqual({
        total: 1,
        processed: 1,
        updated: 0,
        unchanged: 0,
        skipped: 1,
        failed: 0,
    });
    expect(save).not.toHaveBeenCalled();
});

test("reads the edited name and clears a previous date override", async () => {
    const f = file(1, "IMG_3613.heic", desiredTime);
    f.pubMagicMetadata = {
        version: 1,
        count: 3,
        data: {
            editedName: "IMG - 3613 2024-06-29.heic",
            dateTime: "2026-11-12T00:06:00",
            offsetTime: "+02:00",
        },
    };
    const result = await repairFileCreationTimes(
        [f],
        "file-name",
        undefined,
        vi.fn(),
    );
    expect(result.updated).toBe(1);
    expect(save).toHaveBeenCalledWith(f, {
        editedTime: desiredTime,
        dateTime: undefined,
        offsetTime: undefined,
    });
});

test("missing EXIF and unsupported media are skipped", async () => {
    const video = file(2, "video.mp4");
    video.metadata.fileType = FileType.video;
    const result = await repairFileCreationTimes(
        [file(1, "photo.jpg"), video],
        "date-time-digitized",
        undefined,
        vi.fn(),
    );
    expect(result.skipped).toBe(2);
    expect(result.updated).toBe(0);
    expect(download).toHaveBeenCalledTimes(1);
    expect(save).not.toHaveBeenCalled();
});

test("matching EXIF metadata is unchanged and a changed offset is updated", async () => {
    const date: ParsedMetadataDate = {
        dateTime: "2024-06-29T09:50:00",
        offset: "+02:00",
        timestamp: timestamp("2024-06-29T09:50:00+02:00"),
    };
    extractDates.mockResolvedValue({ DateTimeOriginal: date });
    const same = file(1, "same.heic", date.timestamp);
    same.pubMagicMetadata = {
        version: 1,
        count: 2,
        data: { dateTime: date.dateTime, offsetTime: date.offset },
    };
    const changed = structuredClone(same);
    changed.id = 2;
    changed.pubMagicMetadata!.data.offsetTime = "+01:00";
    const result = await repairFileCreationTimes(
        [same, changed],
        "date-time-original",
        undefined,
        vi.fn(),
    );
    expect(result.unchanged).toBe(1);
    expect(result.updated).toBe(1);
    expect(save).toHaveBeenCalledWith(changed, {
        dateTime: date.dateTime,
        offsetTime: date.offset,
        editedTime: date.timestamp,
    });
});

test("custom time discards the computer offset and reports save failures", async () => {
    save.mockRejectedValueOnce(new Error("save failed"));
    const date = {
        dateTime: "2024-06-29T09:50:00",
        offset: "+05:30",
        timestamp: desiredTime,
    };
    const f = file(1, "photo.heic");
    const result = await repairFileCreationTimes([f], "custom", date, vi.fn());
    expect(result.failed).toBe(1);
    expect(result.updated).toBe(0);
    expect(save).toHaveBeenCalledWith(f, {
        dateTime: date.dateTime,
        offsetTime: undefined,
        editedTime: desiredTime,
    });
});

const installVersionedSave = (files: EnteFile[]) => {
    const remote = new Map(files.map((f) => [f.id, structuredClone(f)]));
    const requests: { id: number; version: number }[] = [];
    let failSecondFile = true;
    save.mockImplementation(
        (f: EnteFile, updates: FilePublicMagicMetadataData) => {
            const previous = remote.get(f.id)!;
            const version = f.pubMagicMetadata?.version ?? 1;
            requests.push({ id: f.id, version });
            if (
                previous.pubMagicMetadata &&
                previous.pubMagicMetadata.version != version
            ) {
                return Promise.reject(new Error("version mismatch"));
            }
            if (f.id == 2 && failSecondFile) {
                failSecondFile = false;
                return Promise.reject(new Error("temporary failure"));
            }
            const data = { ...f.pubMagicMetadata?.data, ...updates };
            const { count } = createMagicMetadata(data);
            previous.pubMagicMetadata = { version: version + 1, count, data };
            return Promise.resolve();
        },
    );
    return { remote, requests };
};

test("same-source retry keeps prior successes unchanged and repairs the failed file", async () => {
    const files = [file(1, "2020-01-01.heic"), file(2, "2021-01-01.heic")];
    const { remote, requests } = installVersionedSave(files);
    const date = {
        dateTime: "2024-06-29T00:00:00",
        offset: undefined,
        timestamp: desiredTime,
    };
    extractDates.mockResolvedValue({ DateTimeOriginal: date });
    const first = await repairFileCreationTimes(
        files,
        "date-time-original",
        undefined,
        vi.fn(),
    );
    expect(first.updated).toBe(1);
    expect(first.failed).toBe(1);
    expect(files[1]!.pubMagicMetadata).toBeUndefined();
    const retry = await repairFileCreationTimes(
        files,
        "date-time-original",
        undefined,
        vi.fn(),
    );
    expect(retry).toEqual({
        total: 2,
        processed: 2,
        updated: 1,
        unchanged: 1,
        skipped: 0,
        failed: 0,
    });
    expect(requests).toEqual([
        { id: 1, version: 1 },
        { id: 2, version: 1 },
        { id: 2, version: 1 },
    ]);
    expect(remote.get(1)?.pubMagicMetadata?.data.editedTime).toBe(desiredTime);
    expect(remote.get(2)?.pubMagicMetadata?.data.editedTime).toBe(desiredTime);
});

test("switching a partial EXIF repair to filename uses the saved metadata and next version", async () => {
    const original = timestamp("2020-01-01T00:00:00");
    const files = [
        file(1, "2020-01-01.heic", original),
        file(2, "2021-01-01.heic", timestamp("2021-01-01T00:00:00")),
    ];
    const { remote, requests } = installVersionedSave(files);
    extractDates.mockResolvedValue({
        DateTimeOriginal: {
            dateTime: "2024-06-29T00:00:00",
            offset: undefined,
            timestamp: desiredTime,
        },
    });
    const first = await repairFileCreationTimes(
        files,
        "date-time-original",
        undefined,
        vi.fn(),
    );
    expect(first.failed).toBe(1);
    const retry = await repairFileCreationTimes(
        files,
        "file-name",
        undefined,
        vi.fn(),
    );
    expect(retry).toEqual({
        total: 2,
        processed: 2,
        updated: 1,
        unchanged: 1,
        skipped: 0,
        failed: 0,
    });
    expect(requests).toEqual([
        { id: 1, version: 1 },
        { id: 2, version: 1 },
        { id: 1, version: 2 },
    ]);
    expect(remote.get(1)?.pubMagicMetadata?.data.editedTime).toBe(original);
    expect(remote.get(1)?.pubMagicMetadata?.data.dateTime).toBeUndefined();
    expect(files[0]!.pubMagicMetadata?.version).toBe(3);
});

test("switching a partial custom repair back to EXIF restores the original date and offset", async () => {
    const date = {
        dateTime: "2020-01-01T00:00:00",
        offset: "+02:00",
        timestamp: timestamp("2020-01-01T00:00:00+02:00"),
    };
    const files = [
        file(1, "a.heic", date.timestamp),
        file(2, "b.heic", date.timestamp),
    ];
    for (const f of files) {
        f.pubMagicMetadata = {
            version: 7,
            count: 3,
            data: {
                dateTime: date.dateTime,
                offsetTime: date.offset,
                caption: "Keep this caption",
            },
        };
    }
    const { remote, requests } = installVersionedSave(files);
    extractDates.mockResolvedValue({ DateTimeOriginal: date });
    const first = await repairFileCreationTimes(
        files,
        "custom",
        {
            dateTime: "2024-06-29T00:00:00",
            offset: undefined,
            timestamp: desiredTime,
        },
        vi.fn(),
    );
    expect(first.failed).toBe(1);
    const retry = await repairFileCreationTimes(
        files,
        "date-time-original",
        undefined,
        vi.fn(),
    );
    expect(retry).toEqual({
        total: 2,
        processed: 2,
        updated: 1,
        unchanged: 1,
        skipped: 0,
        failed: 0,
    });
    expect(requests).toEqual([
        { id: 1, version: 7 },
        { id: 2, version: 7 },
        { id: 1, version: 8 },
    ]);
    expect(remote.get(1)?.pubMagicMetadata?.data).toMatchObject({
        dateTime: date.dateTime,
        offsetTime: date.offset,
        editedTime: date.timestamp,
        caption: "Keep this caption",
    });
    expect(files[0]!.pubMagicMetadata?.version).toBe(9);
});
