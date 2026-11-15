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
    let updates: FilePublicMagicMetadataData;
    if (fixOption == "file-name") {
        const editedTime = tryParseEpochMicrosecondsFromFileName(
            fileFileName(file),
        );
        if (editedTime === undefined) return "skipped";
        updates = { editedTime, dateTime: undefined, offsetTime: undefined };
    } else {
        let date = fixOption == "custom" ? customDate : undefined;
        if (fixOption != "custom" && file.metadata.fileType == FileType.image) {
            const blob = await downloadManager.fileBlob(file);
            const {
                DateTimeOriginal,
                DateTimeDigitized,
                MetadataDate,
                DateTime,
            } = await extractExifDates(new File([blob], fileFileName(file)));
            date = {
                "date-time-original": DateTimeOriginal ?? DateTime,
                "date-time-digitized": DateTimeDigitized,
                "metadata-date": MetadataDate,
            }[fixOption];
        }
        if (!date) return "skipped";
        updates = {
            editedTime: date.timestamp,
            dateTime: date.dateTime,
            offsetTime: fixOption == "custom" ? undefined : date.offset,
        };
    }

    const existing = file.pubMagicMetadata?.data;
    if (
        updates.editedTime == fileCreationTime(file) &&
        updates.dateTime === existing?.dateTime &&
        updates.offsetTime === existing?.offsetTime
    )
        return "unchanged";

    const data = { ...existing, ...updates };
    const { version, count } = createMagicMetadata(
        data,
        file.pubMagicMetadata?.version,
    );
    await updateFilePublicMagicMetadata(file, updates);
    file.pubMagicMetadata = { version: version + 1, count, data };
    return "updated";
};
