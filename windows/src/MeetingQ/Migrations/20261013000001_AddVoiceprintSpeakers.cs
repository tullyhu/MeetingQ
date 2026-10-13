using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace MeetingQ.Migrations
{
    /// <inheritdoc />
    public partial class AddVoiceprintSpeakers : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "VoiceprintSpeakers",
                columns: table => new
                {
                    Id = table.Column<long>(type: "INTEGER", nullable: false)
                        .Annotation("Sqlite:Autoincrement", true),
                    Name = table.Column<string>(type: "TEXT", nullable: false, defaultValue: ""),
                    EmbeddingBlob = table.Column<byte[]>(type: "BLOB", nullable: true),
                    SampleCount = table.Column<int>(type: "INTEGER", nullable: false, defaultValue: 0),
                    LastHeardAt = table.Column<string>(type: "TEXT", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_VoiceprintSpeakers", x => x.Id);
                });
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(name: "VoiceprintSpeakers");
        }
    }
}
