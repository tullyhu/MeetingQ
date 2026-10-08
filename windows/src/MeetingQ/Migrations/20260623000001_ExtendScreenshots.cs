using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace MeetingQ.Migrations
{
    /// <inheritdoc />
    public partial class ExtendScreenshots : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            // AISummary already exists in the model — skip it.
            // Add new Vision analysis columns that don't exist yet.
            migrationBuilder.AddColumn<string>(
                name: "OcrText",
                table: "Screenshots",
                type: "TEXT",
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "ContentType",
                table: "Screenshots",
                type: "TEXT",
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "KeyEntities",
                table: "Screenshots",
                type: "TEXT",
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "KeyNumbers",
                table: "Screenshots",
                type: "TEXT",
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "MeetingRelevance",
                table: "Screenshots",
                type: "TEXT",
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "SensitivityLevel",
                table: "Screenshots",
                type: "TEXT",
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "AnalysisStatus",
                table: "Screenshots",
                type: "TEXT",
                nullable: true);

            migrationBuilder.AddColumn<int>(
                name: "RelatedTopicId",
                table: "Screenshots",
                type: "INTEGER",
                nullable: true);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            // SQLite does not support DROP COLUMN in most configurations.
            // Keep the columns but leave them unused on rollback.
        }
    }
}
