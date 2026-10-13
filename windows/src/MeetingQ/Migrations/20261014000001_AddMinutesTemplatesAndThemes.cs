using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace MeetingQ.Migrations
{
    /// <inheritdoc />
    public partial class AddMinutesTemplatesAndThemes : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<string>(
                name: "TemplateId",
                table: "Sessions",
                type: "TEXT",
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "MinutesJson",
                table: "Sessions",
                type: "TEXT",
                nullable: true);

            migrationBuilder.AddColumn<int>(
                name: "QualityScore",
                table: "Sessions",
                type: "INTEGER",
                nullable: true);

            migrationBuilder.AddColumn<int>(
                name: "ThemeId",
                table: "Sessions",
                type: "INTEGER",
                nullable: true);

            migrationBuilder.CreateTable(
                name: "MeetingThemes",
                columns: table => new
                {
                    ThemeId = table.Column<int>(type: "INTEGER", nullable: false)
                        .Annotation("Sqlite:Autoincrement", true),
                    Name = table.Column<string>(type: "TEXT", nullable: false),
                    KeywordsJson = table.Column<string>(type: "TEXT", nullable: false, defaultValue: "[]"),
                    CreatedAt = table.Column<string>(type: "TEXT", nullable: false),
                    IsArchived = table.Column<bool>(type: "INTEGER", nullable: false, defaultValue: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_MeetingThemes", x => x.ThemeId);
                });

            migrationBuilder.CreateIndex(
                name: "IX_Sessions_ThemeId",
                table: "Sessions",
                column: "ThemeId");

            migrationBuilder.AddForeignKey(
                name: "FK_Sessions_MeetingThemes_ThemeId",
                table: "Sessions",
                column: "ThemeId",
                principalTable: "MeetingThemes",
                principalColumn: "ThemeId",
                onDelete: ReferentialAction.SetNull);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropForeignKey(
                name: "FK_Sessions_MeetingThemes_ThemeId",
                table: "Sessions");

            migrationBuilder.DropTable(name: "MeetingThemes");

            migrationBuilder.DropIndex(
                name: "IX_Sessions_ThemeId",
                table: "Sessions");

            migrationBuilder.DropColumn(name: "TemplateId", table: "Sessions");
            migrationBuilder.DropColumn(name: "MinutesJson", table: "Sessions");
            migrationBuilder.DropColumn(name: "QualityScore", table: "Sessions");
            migrationBuilder.DropColumn(name: "ThemeId", table: "Sessions");
        }
    }
}
