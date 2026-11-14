import log from "ente-base/log";
import { downloadManager } from "ente-gallery/services/download";
import { extractExifDates } from "ente-gallery/services/exif";
import { tryParseEpochMicrosecondsFromFileName } from "ente-gallery/services/upload/date";
import { fileLogID, type EnteFile } from "ente-media/file";
import {
    fileCreationTime,
    fileFileName,
    type FilePublicMagicMetadataData,
    type ParsedMetadataDate,
} from "ente-media/file-metadata";
import { FileType } from "ente-media/file-type";
import { createMagicMetadata } from "ente-media/magic-metadata";
import { updateFilePublicMagicMetadata } from "ente-new/photos/services/file";

export type FileTimeRepairOption =
    | "date-time-original"
    | "date-time-digitized"
    | "metadata-date"
    | "file-name"
    | "custom";

export interface FileTimeRepairProgress {
    total: number;
    processed: number;
    updated: number;
    unchanged: number;
    skipped: number;
    failed: number;
}

export const initialFileTimeRepairProgress = (
    total: number,
): FileTimeRepairProgress => ({
    total,
    processed: 0,
    updated: 0,
    unchanged: 0,
    skipped: 0,
    failed: 0,
});

export const repairFileCreationTimes = async (
    files: EnteFile[],
    fixOption: FileTimeRepairOption,
    customDate: ParsedMetadataDate | undefined,
    setProgress: (progress: FileTimeRepairProgress) => void,
) => {
    let progress = initialFileTimeRepairProgress(files.length);
    setProgress(progress);
    for (const file of files) {
        try {
            const outcome = await updateFileDate(file, fixOption, customDate);
            progress = { ...progress, [outcome]: progress[outcome] + 1 };
        } catch (e) {
            log.error(`Failed to update date of ${fileLogID(file)}`, e);
            progress = { ...progress, failed: progress.failed + 1 };
        } finally {
            progress = { ...progress, processed: progress.processed + 1 };
            setProgress(progress);
        }
    }
    return progress;
};

const updateFileDate = async (
    file: EnteFile,
    fixOption: FileTimeRepairOption,
    customDate: ParsedMetadataDate | undefined,
): Promise<"updated" | "unchanged" | "skipped"> => {
    let newDate: ParsedMetadataDate | undefined;

    if (fixOption == "custom") {
        newDate = customDate && {
            dateTime: customDate.dateTime,
            offset: undefined,
            timestamp: customDate.timestamp,
        };
    } else if (fixOption == "file-name") {
        const editedTime = tryParseEpochMicrosecondsFromFileName(
            fileFileName(file),
        );
        if (editedTime === undefined) return "skipped";

        const existing = file.pubMagicMetadata?.data;
        if (
            editedTime == fileCreationTime(file) &&
            existing?.dateTime === undefined &&
            existing?.offsetTime === undefined
        )
            return "unchanged";

        await saveFileDate(file, {
            editedTime,
            dateTime: undefined,
            offsetTime: undefined,
        });
        return "updated";
    } else if (file.metadata.fileType == FileType.image) {
        const blob = await downloadManager.fileBlob(file);
        const { DateTimeOriginal, DateTimeDigitized, MetadataDate, DateTime } =
            await extractExifDates(new File([blob], fileFileName(file)));

        switch (fixOption) {
            case "date-time-original":
                newDate = DateTimeOriginal ?? DateTime;
                break;
            case "date-time-digitized":
                newDate = DateTimeDigitized;
                break;
            case "metadata-date":
                newDate = MetadataDate;
                break;
        }
    }

    if (!newDate) return "skipped";

    const existing = file.pubMagicMetadata?.data;
    if (
        newDate.timestamp == fileCreationTime(file) &&
        newDate.dateTime == existing?.dateTime &&
        newDate.offset === existing.offsetTime
    )
        return "unchanged";

    await saveFileDate(file, {
        dateTime: newDate.dateTime,
        offsetTime: newDate.offset,
        editedTime: newDate.timestamp,
    });
    return "updated";
};

const saveFileDate = async (
    file: EnteFile,
    updates: FilePublicMagicMetadataData,
) => {
    const data = { ...file.pubMagicMetadata?.data, ...updates };
    const { version, count } = createMagicMetadata(
        data,
        file.pubMagicMetadata?.version,
    );
    await updateFilePublicMagicMetadata(file, updates);
    file.pubMagicMetadata = { version: version + 1, count, data };
};
