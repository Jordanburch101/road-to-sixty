CREATE INDEX "session_user" ON "session" USING btree ("user_id");--> statement-breakpoint
CREATE INDEX "verification_identifier" ON "verification" USING btree ("identifier");--> statement-breakpoint
ALTER TABLE "device_code" ADD CONSTRAINT "device_code_device_code_unique" UNIQUE("device_code");--> statement-breakpoint
ALTER TABLE "device_code" ADD CONSTRAINT "device_code_user_code_unique" UNIQUE("user_code");