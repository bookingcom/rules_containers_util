package dockerfile

import (
	"fmt"
	"strings"

	"mvdan.cc/sh/v3/syntax"
)

// ShellNode represents an AST node in the shell command AST.
type ShellNode struct {
	Type     string       `json:"type"`
	Op       string       `json:"op,omitempty"`       // For binary commands (&&, ||, |)
	Args     []string     `json:"args,omitempty"`     // Flattened arguments for CallExpr
	Children []*ShellNode `json:"children,omitempty"` // Child AST nodes
	Raw      string       `json:"raw,omitempty"`      // Raw text representation
}

// ParseShellCommand parses a shell command string into a ShellNode AST.
func ParseShellCommand(cmd string) (*ShellNode, error) {
	parser := syntax.NewParser(syntax.KeepComments(false))
	file, err := parser.Parse(strings.NewReader(cmd), "")
	if err != nil {
		return nil, fmt.Errorf("failed to parse shell command: %w", err)
	}

	return convertFile(file), nil
}

func convertFile(f *syntax.File) *ShellNode {
	node := &ShellNode{
		Type: "Script",
	}
	for _, stmt := range f.Stmts {
		if stmtNode := convertStmt(stmt); stmtNode != nil {
			node.Children = append(node.Children, stmtNode)
		}
	}
	return node
}

func convertStmt(stmt *syntax.Stmt) *ShellNode {
	if stmt == nil || stmt.Cmd == nil {
		return nil
	}

	node := convertCmd(stmt.Cmd)
	if stmt.Negated && node != nil {
		node = &ShellNode{
			Type:     "Negated",
			Children: []*ShellNode{node},
		}
	}
	if stmt.Background && node != nil {
		node = &ShellNode{
			Type:     "Background",
			Children: []*ShellNode{node},
		}
	}
	return node
}

func convertCmd(cmd syntax.Command) *ShellNode {
	switch c := cmd.(type) {
	case *syntax.CallExpr:
		var args []string
		for _, w := range c.Args {
			args = append(args, wordToString(w))
		}
		return &ShellNode{
			Type: "CallExpr",
			Args: args,
		}

	case *syntax.BinaryCmd:
		return &ShellNode{
			Type: "BinaryCmd",
			Op:   c.Op.String(),
			Children: []*ShellNode{
				convertStmt(c.X),
				convertStmt(c.Y),
			},
		}

	case *syntax.Block:
		node := &ShellNode{Type: "Block"}
		for _, stmt := range c.Stmts {
			if s := convertStmt(stmt); s != nil {
				node.Children = append(node.Children, s)
			}
		}
		return node

	case *syntax.Subshell:
		node := &ShellNode{Type: "Subshell"}
		for _, stmt := range c.Stmts {
			if s := convertStmt(stmt); s != nil {
				node.Children = append(node.Children, s)
			}
		}
		return node

	case *syntax.IfClause:
		node := &ShellNode{Type: "IfClause"}
		for _, stmt := range c.Cond {
			if s := convertStmt(stmt); s != nil {
				node.Children = append(node.Children, s)
			}
		}
		for _, stmt := range c.Then {
			if s := convertStmt(stmt); s != nil {
				node.Children = append(node.Children, s)
			}
		}
		return node

	default:
		// Fallback generic node
		return &ShellNode{
			Type: fmt.Sprintf("%T", cmd),
		}
	}
}

func wordToString(w *syntax.Word) string {
	if w == nil {
		return ""
	}
	var sb strings.Builder
	for _, part := range w.Parts {
		switch p := part.(type) {
		case *syntax.Lit:
			sb.WriteString(p.Value)
		case *syntax.SglQuoted:
			sb.WriteString(p.Value)
		case *syntax.DblQuoted:
			for _, qp := range p.Parts {
				if lit, ok := qp.(*syntax.Lit); ok {
					sb.WriteString(lit.Value)
				} else if pe, ok := qp.(*syntax.ParamExp); ok {
					sb.WriteString("$")
					sb.WriteString(pe.Param.Value)
				}
			}
		case *syntax.ParamExp:
			sb.WriteString("$")
			sb.WriteString(p.Param.Value)
		default:
			// Fallback: syntax print
			var b strings.Builder
			syntax.NewPrinter().Print(&b, part)
			sb.WriteString(b.String())
		}
	}
	return sb.String()
}
