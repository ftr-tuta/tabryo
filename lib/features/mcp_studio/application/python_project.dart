Map<String, String> pythonProject(String name) => {
  'requirements.txt': 'mcp==2.1.1\npytest==9.1.1\n',
  '.gitignore': '.venv/\n__pycache__/\n.pytest_cache/\n',
  'server.py':
      '''from mcp.server import MCPServer

mcp = MCPServer("$name")


@mcp.tool()
def greet(name: str) -> str:
    """Create a friendly greeting."""
    return f"Hello, {name}!"


@mcp.resource("greeting://info")
def information() -> str:
    """Read information about this local server."""
    return "A local greeting server."


@mcp.prompt()
def welcome(name: str) -> str:
    """Draft a welcome message."""
    return f"Welcome {name} warmly."


if __name__ == "__main__":
    # STDOUT belongs to MCP. Use logging (stderr) for application messages.
    mcp.run(transport="stdio")
''',
  'test_server.py': '''import pytest
from mcp import Client
from server import mcp


@pytest.fixture
def anyio_backend():
    return "asyncio"


@pytest.mark.anyio
async def test_greeting_resource_and_prompt():
    async with Client(mcp) as client:
        tools = await client.list_tools()
        assert any(tool.name == "greet" for tool in tools.tools)
        result = await client.call_tool("greet", {"name": "Ada"})
        assert result.content[0].text == "Hello, Ada!"
        resources = await client.list_resources()
        assert any(str(resource.uri) == "greeting://info" for resource in resources.resources)
        result = await client.read_resource("greeting://info")
        assert "local greeting" in result.contents[0].text
        prompts = await client.list_prompts()
        assert any(prompt.name == "welcome" for prompt in prompts.prompts)
        result = await client.get_prompt("welcome", {"name": "Ada"})
        assert "Ada" in result.messages[0].content.text
''',
};
