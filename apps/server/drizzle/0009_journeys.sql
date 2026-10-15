ALTER TABLE "characters" DROP CONSTRAINT "characters_user_id_game_realm_name_unique";--> statement-breakpoint
ALTER TABLE "characters" ADD COLUMN "journey" text;--> statement-breakpoint
ALTER TABLE "versions" ADD COLUMN "journey" text;--> statement-breakpoint
ALTER TABLE "characters" ADD CONSTRAINT "characters_user_id_game_realm_name_journey_unique" UNIQUE NULLS NOT DISTINCT("user_id","game","realm","name","journey");