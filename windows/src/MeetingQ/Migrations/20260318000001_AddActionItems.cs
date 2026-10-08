using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace MeetingQ.Migrations
{
    /// <inheritdoc />
    public partial class AddActionItems : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "ActionItems",
                columns: table => new
                {
                    ActionItemId = table.Column<int>(type: "INTEGER", nullable: false)
                        .Annotation("Sqlite:Autoincrement", true),
                    Timestamp  = table.Column<DateTime>(type: "TEXT", nullable: false),
                    AssignedTo = table.Column<string>(type: "TEXT", nullable: false),
                    Task       = table.Column<string>(type: "TEXT", nullable: false),
                    Deadline   = table.Column<string>(type: "TEXT", nullable: true),
                    TopicId    = table.Column<int>(type: "INTEGER", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_ActionItems", x => x.ActionItemId);
                    table.ForeignKey(
                        name: "FK_ActionItems_Topics_TopicId",
                        column: x => x.TopicId,
                        principalTable: "Topics",
                        principalColumn: "TopicId",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateIndex(
                name: "IX_ActionItems_TopicId",
                table: "ActionItems",
                column: "TopicId");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(name: "ActionItems");
        }
    }
}
