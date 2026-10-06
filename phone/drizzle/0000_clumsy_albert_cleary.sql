CREATE TABLE `channels` (
	`id` text PRIMARY KEY NOT NULL,
	`auth_hash` text NOT NULL,
	`created_at` integer NOT NULL
);
--> statement-breakpoint
CREATE TABLE `events` (
	`seq` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`channel` text NOT NULL,
	`id` text NOT NULL,
	`payload` text NOT NULL,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`channel`) REFERENCES `channels`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE UNIQUE INDEX `event_id` ON `events` (`channel`,`id`);--> statement-breakpoint
CREATE INDEX `channel_seq` ON `events` (`channel`,`seq`);