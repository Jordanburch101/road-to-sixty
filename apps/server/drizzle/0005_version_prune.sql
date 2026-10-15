ALTER TABLE "versions" ADD COLUMN "weekly" boolean DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE "versions" ADD COLUMN "pruned_at" timestamp with time zone;