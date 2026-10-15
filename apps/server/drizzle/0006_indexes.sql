CREATE INDEX "devices_user" ON "devices" USING btree ("user_id");--> statement-breakpoint
CREATE INDEX "jobs_due" ON "jobs" USING btree ("id") WHERE "jobs"."state" IN ('queued', 'running');--> statement-breakpoint
CREATE INDEX "jobs_version" ON "jobs" USING btree ("version_id");--> statement-breakpoint
CREATE INDEX "jobs_character" ON "jobs" USING btree ("character_id");--> statement-breakpoint
CREATE INDEX "version_parents_parent" ON "version_parents" USING btree ("parent_id");--> statement-breakpoint
CREATE INDEX "versions_character" ON "versions" USING btree ("character_id","id");--> statement-breakpoint
CREATE INDEX "versions_device_upload" ON "versions" USING btree ("device_id","character_id","id") WHERE "versions"."kind" = 'upload';