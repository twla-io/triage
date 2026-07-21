import { Component, type ErrorInfo, type ReactNode } from 'react'
import { Alert, Container, Text } from '@mantine/core'

interface Props {
  children: ReactNode
}

interface State {
  error: Error | null
}

// Minimal: a request failing shouldn't crash the app. No retry affordance,
// no reporting -- just a fallback message instead of a blank white screen.
export class ErrorBoundary extends Component<Props, State> {
  state: State = { error: null }

  static getDerivedStateFromError(error: Error): State {
    return { error }
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    console.error('Unhandled UI error:', error, info.componentStack)
  }

  render() {
    if (this.state.error) {
      return (
        <Container size="sm" py="xl">
          <Alert color="red" title="Something went wrong">
            <Text size="sm">{this.state.error.message}</Text>
          </Alert>
        </Container>
      )
    }
    return this.props.children
  }
}
