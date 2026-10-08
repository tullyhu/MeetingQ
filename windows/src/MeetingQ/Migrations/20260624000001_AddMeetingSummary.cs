using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace MeetingQ.Migrations
{
    /// <inheritdoc />
    public partial class AddMeetingSummary : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<string>(
                name: "Summary",
                table: "Sessions",
                type: "TEXT",
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "ActiveSpeakerName",
                table: "Screenshots",
                type: "TEXT",
                nullable: true);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            // SQLite does not support DROP COLUMN in most configurations.
            // Keep the column but leave it unused on rollback.
        }
    }
}
