CREATE TABLE "characters" (
	"id" bigserial PRIMARY KEY NOT NULL,
	"user_id" text NOT NULL,
	"game" text NOT NULL,
	"realm" text NOT NULL,
	"name" text NOT NULL,
	"class" text,
	"level" integer,
	"played" integer,
	"last_played_at" timestamp with time zone,
	"head_version_id" bigint,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "characters_user_id_game_realm_name_unique" UNIQUE("user_id","game","realm","name")
);
--> statement-breakpoint
CREATE TABLE "devices" (
	"id" text PRIMARY KEY NOT NULL,
	"user_id" text NOT NULL,
	"name" text NOT NULL,
	"platform" text,
	"app_version" text,
	"addon_version" text,
	"data_layout" integer,
	"token_hash" text NOT NULL,
	"last_seen_at" timestamp with time zone,
	"revoked_at" timestamp with time zone,
	CONSTRAINT "devices_token_hash_unique" UNIQUE("token_hash")
);
--> statement-breakpoint
CREATE TABLE "jobs" (
	"id" bigserial PRIMARY KEY NOT NULL,
	"character_id" bigint NOT NULL,
	"version_id" bigint NOT NULL,
	"state" text DEFAULT 'queued' NOT NULL,
	"attempts" integer DEFAULT 0 NOT NULL,
	"error" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"finished_at" timestamp with time zone
);
--> statement-breakpoint
CREATE TABLE "version_parents" (
	"version_id" bigint NOT NULL,
	"parent_id" bigint NOT NULL,
	CONSTRAINT "version_parents_version_id_parent_id_pk" PRIMARY KEY("version_id","parent_id")
);
--> statement-breakpoint
CREATE TABLE "versions" (
	"id" bigserial PRIMARY KEY NOT NULL,
	"character_id" bigint NOT NULL,
	"device_id" text,
	"kind" text NOT NULL,
	"fingerprint" text NOT NULL,
	"raw_size" integer NOT NULL,
	"data_version" integer,
	"addon_version" text,
	"received_id" bigint,
	"status" text NOT NULL,
	"reject_reason" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "jobs" ADD CONSTRAINT "jobs_character_id_characters_id_fk" FOREIGN KEY ("character_id") REFERENCES "public"."characters"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "jobs" ADD CONSTRAINT "jobs_version_id_versions_id_fk" FOREIGN KEY ("version_id") REFERENCES "public"."versions"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "version_parents" ADD CONSTRAINT "version_parents_version_id_versions_id_fk" FOREIGN KEY ("version_id") REFERENCES "public"."versions"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "version_parents" ADD CONSTRAINT "version_parents_parent_id_versions_id_fk" FOREIGN KEY ("parent_id") REFERENCES "public"."versions"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "versions" ADD CONSTRAINT "versions_character_id_characters_id_fk" FOREIGN KEY ("character_id") REFERENCES "public"."characters"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "versions" ADD CONSTRAINT "versions_device_id_devices_id_fk" FOREIGN KEY ("device_id") REFERENCES "public"."devices"("id") ON DELETE no action ON UPDATE no action;